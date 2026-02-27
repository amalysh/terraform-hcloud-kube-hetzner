locals {
  templates_path = var.templates_path != "" ? var.templates_path : "${path.module}/templates"
}
