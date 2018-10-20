# Normal servers have version 1 of KV mounted by default, so will need these
# paths:
path "secret/example/*" {
  capabilities = ["read"]
}
