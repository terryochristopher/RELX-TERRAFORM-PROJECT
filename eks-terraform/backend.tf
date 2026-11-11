terraform {
  backend "s3" {
    bucket       = "test-bucket-relx-new"
    key          = "relx-eks-project/eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}