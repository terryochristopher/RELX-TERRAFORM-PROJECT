data "aws_ssm_parameter" "ami-data" {
     name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" 
}

resource "aws_key_pair" "relx-key" {
     key_name = "${var.project-name}-${var.environment}-key"
     public_key = var.ssh_public_key 
}

resource "aws_instance" "relx-bastion" {
    ami = data.aws_ssm_parameter.ami-data.value
    instance_type = var.instance_type
    subnet_id = aws_subnet.relx-publicsubnet.id
    vpc_security_group_ids = [aws_security_group.relx-bastion.id]
    key_name = aws_key_pair.relx-key.key_name
    metadata_options {
         http_tokens = "required" 
    }
    root_block_device {
        encrypted = true
        volume_size = 8
        volume_type = "gp3" 
    }
    tags = {
        Name = "${var.project-name}-${var.environment}-bastion" 
    }
}

resource "aws_iam_role" "relx-web" {
  name = "${var.project-name}-${var.environment}-web-role"
  assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
            Effect = "Allow",
            Principal = {
                Service = "ec2.amazonaws.com" 
            }, 
            Action = "sts:AssumeRole" 
        }] 
    })
}

resource "aws_iam_role_policy" "web-metric" {
  name = "relx-cloudwatch-only-custom-metrics"
  role = aws_iam_role.relx-web.id
  policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
            Effect = "Allow",
            Action = ["cloudwatch:PutMetricData"],
            Resource = "*",
            Condition = {
                StringEquals = { 
                    "cloudwatch:namespace" = "SREExercise/Web" 
                }
            } 
        }] 
    
    })
}

# CloudWatch Agent resolves the ASG dimension from EC2 tags.
resource "aws_iam_role_policy" "relx-web-tags" {
  name = "relx-describe-instance-tags"
  role = aws_iam_role.relx-web.id
  policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{ 
            Effect = "Allow", 
            Action = ["ec2:DescribeTags"], 
            Resource = "*" 
        }]
    })
}

resource "aws_iam_instance_profile" "relx-web" { 
    name = "${var.project-name}-${var.environment}-web-profile"
    role = aws_iam_role.relx-web.name 
}
resource "aws_lb" "relx-web" {
    name = "${var.project-name}-${var.environment}-alb"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.relx-alb.id]
    subnets = [
        aws_subnet.relx-publicsubnet.id,
        aws_subnet.relx-publicsubnet_2.id,
        aws_subnet.relx-publicsubnet_3.id
        ]
    enable_deletion_protection = false
}

resource "aws_lb_target_group" "relx-web" {
    name = "${var.project-name}-${var.environment}-tg"
    port = 80
    protocol = "HTTP"
    vpc_id = aws_vpc.main.id
    health_check { 
        enabled = true
        path = "/"
        matcher = "200"
        healthy_threshold = 2
        unhealthy_threshold = 3 
    }
}
resource "aws_lb_listener" "relx-http" { 
    load_balancer_arn = aws_lb.relx-web.arn
    port = 80
    protocol = "HTTP"
    default_action { 
        type = "forward"
        target_group_arn = aws_lb_target_group.relx-web.arn 
    }
}

resource "aws_launch_template" "relx-web" {
    name_prefix = "${var.project-name}-${var.environment}-launchweb"
    image_id = data.aws_ssm_parameter.ami-data.value
    instance_type = var.instance_type
    key_name = aws_key_pair.relx-key.key_name
    iam_instance_profile { 
        arn = aws_iam_instance_profile.relx-web.arn 
    }
    vpc_security_group_ids = [
        aws_security_group.web.id
    ]
    user_data = base64encode(templatefile(
        "${path.module}/templates/user_data.sh.tftpl", 
        { aws_region = var.aws_region }
        ))
    metadata_options { 
        http_tokens = "required" 
    }
    block_device_mappings { 
        device_name = "/dev/xvda"
        ebs { 
            volume_size = 8
            volume_type = "gp3"
            encrypted = true 
        } 
    }
    tag_specifications { 
        resource_type = "instance"
        tags = { 
            Name = "${var.project-name}-${var.environment}-web" 
        } 
    }
}

resource "aws_autoscaling_group" "relx-web" {
    name = "${var.project-name}-${var.environment}-asg"
    min_size = 1
    max_size = 3
    desired_capacity = 1
    vpc_zone_identifier = aws_subnet.relx-privatesubnet[*].id
    target_group_arns = [aws_lb_target_group.relx-web.arn]
    health_check_type = "ELB"
    health_check_grace_period = 300
    launch_template { 
        id = aws_launch_template.relx-web.id
        version = "$Latest" 
    }
    depends_on = [
        aws_route.private_default
    ]
    tag { 
        key = "Name"
        value = "${var.project-name}-${var.environment}-asgweb"
        propagate_at_launch = true 
    }
}

resource "aws_autoscaling_policy" "relx-cpu" {
    name = "${var.project-name}-${var.environment}-cpu-scale"
    autoscaling_group_name = aws_autoscaling_group.relx-web.name
    policy_type = "TargetTrackingScaling"
    target_tracking_configuration { 
        predefined_metric_specification { 
            predefined_metric_type = "ASGAverageCPUUtilization" 
        }
        target_value = 70.0 
    }
}

resource "aws_sns_topic" "relx-sns" { 
    name = "${var.project-name}-${var.environment}-alarms-sns" 
}
resource "aws_sns_topic_subscription" "email" {
    topic_arn = aws_sns_topic.relx-sns.arn
    protocol = "email"
    endpoint = "${var.alert_email}"
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
    alarm_name = "${var.project-name}-${var.environment}-cpu-over-70"
    namespace = "AWS/EC2"
    metric_name = "CPUUtilization"
    dimensions = { 
        AutoScalingGroupName = aws_autoscaling_group.relx-web.name 
    }
    statistic = "Average"
    period = 300
    evaluation_periods = 2
    threshold = 70
    comparison_operator = "GreaterThanThreshold"
    treat_missing_data = "notBreaching"
    alarm_actions = [aws_sns_topic.relx-sns.arn]
}

resource "aws_cloudwatch_metric_alarm" "memory" {
    alarm_name = "${var.project-name}-${var.environment}-memory-over-80"
    namespace = "SREExercise/Web"
    metric_name = "mem_used_percent"
    dimensions = { 
        AutoScalingGroupName = aws_autoscaling_group.relx-web.name 
    }
    statistic = "Average"
    period = 300
    evaluation_periods = 2
    threshold = 80
    comparison_operator = "GreaterThanThreshold"
    treat_missing_data = "notBreaching"
    alarm_actions = [aws_sns_topic.relx-sns.arn]
}