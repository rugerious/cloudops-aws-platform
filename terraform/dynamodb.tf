# The incidents table: same design as the console-built cloudops-dev-incidents
# (checked against the 14 Oct inventory), plus backups and delete protection.

resource "aws_dynamodb_table" "incidents" {
  name         = "${local.name_prefix}-incidents" # cloudops-prod-incidents
  billing_mode = "PAY_PER_REQUEST"                # on-demand: pay per request, no capacity planning
  hash_key     = "incidentId"

  # Only attributes used as keys (table or index) are declared here.
  # All other fields (title, severity, history...) are schemaless.
  attribute {
    name = "incidentId"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }

  # Active / To verify / Closed tabs: Query by status, newest or oldest first.
  # (key_schema replaces the deprecated hash_key/range_key inside an index, AWS provider v6.x)
  global_secondary_index {
    name            = "status-createdAt-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "status"
      key_type       = "HASH" # partition key
    }
    key_schema {
      attribute_name = "createdAt"
      key_type       = "RANGE" # sort key
    }
  }

  # NEW vs the console version: restore the table to any second of the last 35 days.
  point_in_time_recovery {
    enabled = true
  }

  # NEW: AWS refuses to delete the table while this is true
  # (protects the data from a mistaken 'terraform destroy').
  deletion_protection_enabled = true
}

output "incidents_table_name" {
  value = aws_dynamodb_table.incidents.name
}
