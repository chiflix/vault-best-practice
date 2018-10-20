# Vault 的一个最佳实践
在之前的文章「防拖库的最佳实践」中，我提到了使用 Vault 來存储秘钥的方案。本文是我在开发中使用的最佳实践。

## 准备工作

首先生成一套部署 Vault 所需要的证书。在这里我使用了 `cfssl` 这个工具，在 Mac 下可以使用 `brew install cfssl` 来安装。

1. 创建一个 `ca-csr.json` 配置文件，例如 [ca/ca-csr.json](ca/ca-csr.json)。

  之后运行命令 `cfssl gencert -initca ../ca/ca-csr.json | cfssljson -bare ca`
生成 `ca.pem` 和 `ca-key.pem`。

- 再创建一个 `ca-config.json` 配置文件，例如 [ca/ca-config.json](ca/ca-config.json)。 和 `vault-csr.json` 配置文件，例如 [ca/vault-csr.json](ca/vault-csr.json) 之后运行命令：
  ```
  cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=./ca/ca-config.json \
  -hostname="vault,localhost,127.0.0.1,vault.of.your.custom.domain.name.com" \
  -profile=default \
  ./vault-csr.json | cfssljson -bare vault
  ```
- 生成 `vault.pem` 后再运行 `cat vault.pem ca.pem > vault-combined.pem` 将 vault 的证书和 ca 证书合并。

这时我们应该有一组 `ca-key.pem` 和 `vault-combined.pem`。

## 在 k8s 上部署

假设我们已经有一套 k8s 在线，而且可以使用 `kubectl` 命令控制。

1. 先将 ca 证书， vault 的证书和秘钥写入 k8s 的 secret 中。
  ```
  kubectl create secret generic vault-tls \
  --from-file=ca.pem \
  --from-file=vault.pem=vault-combined.pem \
  --from-file=vault-key.pem
  ```

- 创建 vault 配置文件 `vault.hcl`。如果是开发环境，不需要高可用（HA)，我会推荐使用 mysql 作为存储服务配置，例如 [vault-mysql.hcl](vault-mysql.hcl)。 如果是线上环境，我推荐使用支持 高可用（HA) 的存储层，例如 Google Cloud Storage [vault-gcs.hcl](vault-gcs.hcl)。

  - 可以在 `gcloud` 的 `console` 中使用 `gsutil mb gs://vault_storage_bucket_name` 命令创建 gcs 的 bucket。

- 将 vault 的配置文件 `vault.hcl` 写入 k8s 的 configmap。
  ```
  kubectl create secret generic vault-config \
  --from-file=vault.hcl
  ```

- 创建一个 k8s 服务配置文件 `vault.yml` ，例如开发测试环境配置 [vault-stage.yml](vault-stage.yml)，或者生产环境 [vault-prod.yml](vault-prod.yml)

- 将域名配置写入 configmap。

  ```
  kubectl create configmap vault \
  --from-literal \
  api-addr=https://vault.of.your.custom.domain.name.com:8200
  ```

- 如果使用了 gcs ，将谷歌的 `service-account-cert.json`，例如 `vault-service-account-cert-example.json` （这个文件是 gcp 平台上生成的）。写入 secret 。

  ```
  kubectl create secret generic vault-gcs \
    --from-file=service-account-cert.json
  ```

- 启动 vault 服务

  `kubectl apply -f vault.yaml`

### 初始化 vault

vault 在初始化之前是不能正常服务，而且面向 k8s 的健康检查服务也会显示不正常。所以要先登录初始化。

1. 通过 `kubectl get pods` 找到 vault 服务的 pod id。如果是按前面开发测试（stage）环境的配置，这个 pod id 应该是 `vault-0`。如果是生产环境，应该是 `vault-` 后一串随机的 id。 通过 `kubectl` 登录进入这个pod的命令行：

  `kubectl exec -it `*`vault-0`*` -- /bin/sh`

- 初始化 vault。

  `vault operator init -ca-cert=/etc/vault/tls/ca.pem`

  初始化 vault 的操作只有第一次创建部署 vault 时。会生成5个 root tokens。一定要保存好。初始化成功之后，就不需要也不会再运行 init 的操作。

- unseal vault。这个操作使用初始化时生成的 root tokens 中的任意3个，在每次 vault 集群启动后都要运行。

  `vault operator unseal -ca-cert=/etc/vault/tls/ca.pem`

  至此完成 vault 服务的部署。

## 使用 vault

完成 vault 的初始化（init）和 unseal 之后。 k8s 集群应该就会显示 vault 服务健康状态正常，并开始提供服务。这时就可以在任何一个可以访问到这个 vault 服务的实例上，使用 vault 命令行，或者在代码中使用 vault 的库来存取 vault 数据。

1. 使用命令行，先配置环境变量

  ```
  export VAULT_ADDR=https://vault.of.your.custom.domain.name.com:8200
  export VAULT_CACERT=./ca.pem
  export VAULT_TOKEN=your-vault-token
  ```

- 创建一个 policy 配置，例如 [vault-policy-example.hcl](vault-policy-example.hcl)。并通过 vault 命令行创建这个 policy。

  ```
  export VAULT_ADDR=https://vault.of.your.custom.domain.name.com:8200 export VAULT_CACERT=./ca.pem
  export VAULT_TOKEN=your-vault-token
  ```

- 在 secret/example 下写入一个键值。例如写入一个文件或 key。

  ```
  vault kv put secret/example/foobar \
  grpc_tls_cert=@vault-combined.pem \
  gcloud_apikey="your-gcloud-api-key"
  ```

- 创建一个 policy 配置，例如一个 secret/example/* 下的只读策略， [vault-policy-example-readonly.hcl](vault-policy-example-readonly.hcl)。并通过 vault 命令行创建这个 policy。

  `policy write example-readonly vault-policy-example-readonly.hcl`

- 为这个 policy 创建一个 token。这个 token 仅有读取这个 policy 下的键值权限。因此更适合应用中使用。

  `vault token create -policy=example-readonly`

- 之后我们就可以在代码中通过这个 readonly 的 token 来读路径下的键值。假设我们使用 golang。

  ```go
  ...

  import (
  	...
  	vault "github.com/hashicorp/vault/api"
  )

  ...
  // 配置 vault api 的地址
  vaultAddr := os.Getenv("VAULT_API_ADDR")
  config := &vault.Config{
  	Address: vaultAddr,
  }

  // 配置 vault 的 CA Cert
  if err := config.ConfigureTLS(&vault.TLSConfig{
  	CACert: os.Getenv("CA_CERT"),
  }); err != nil {
  	log.Fatalf("failed to configure vault tls: %v", err)
  }
  vaultClient, err := vault.NewClient(config)
  if err != nil {
  	log.Fatalf("failed to init vault client %s: %v", vaultAddr, err)
  }
  // 配置 vault 的 token
  vaultClient.SetToken(os.Getenv("VAULT_TOKEN"))

  keyName := "secret/example/foobar"
  secretValues, err := vaultClient.Logical().Read(keyName)
  if err != nil {
  	log.Fatalf("failed to read vault secret %s: %v", keyName, err)
  }

  // 列印配置信息
  fmt.Println(secretValues.Data["gcloud_apikey"].(string))
  fmt.Println(secretValues.Data["grpc_tls_cert"].(string))
  ```

---

这就是我在 k8s 集群上使用 vault 的方式了。
