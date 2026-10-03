# KV v2 example policy: read only one application prefix.
path "secret/data/demo/*" {
  capabilities = ["read"]
}
path "secret/metadata/demo/*" {
  capabilities = ["list", "read"]
}
