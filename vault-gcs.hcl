listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/tls/vault.pem"
  tls_key_file = "/etc/vault/tls/vault-key.pem"
  tls_min_version = "tls12"
}
storage "gcs" {
  bucket     = "[vault_storage_bucket_name]"
  ha_enabled = "true"
}
