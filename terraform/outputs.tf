output "alb_url" {
  value = "http://${aws_lb.relx-web.dns_name}"
}
output "bastion_public_ip" {
  value = aws_instance.relx-bastion.public_ip
}
output "asg_name" {
  value = aws_autoscaling_group.relx-web.name
}
output "sns_topic_arn" {
  value = aws_sns_topic.relx-sns.arn
}
output "vpc_id" {
  value = aws_vpc.main.id
}