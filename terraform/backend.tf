terraform {
  backend "s3" {
    bucket = "tetris-terraform-state-jatinthakur029"
    key = "terraform.tfstate"
    region = "us-east-1"
    use_lockfile = true
  }
}