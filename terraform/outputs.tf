# Values printed after plan/apply. More are added as resources are built.
output "account_id" {
  value = local.account_id
}

output "region" {
  value = data.aws_region.current.region
}

output "name_prefix" {
  value = local.name_prefix
}
