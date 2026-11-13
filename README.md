# mecaniQA-fortaleza2
Isolamento e containerização da API Java, MySQL e Redis para a MecâniQA Tech.

#Equipe#

Joaqson Rodrigues Miranda;

Lucas Santos Oliveira;

Manoel Souza Santos;

Monique Prado Pereira Gomes;

Raian Rocha Santos;

## Ambiente Docker

Suba a API Java, o MySQL e o Redis com um único comando:

```bash
docker compose up -d --build
```

Confira o estado dos serviços e os healthchecks:

```bash
docker compose ps
docker compose exec api getent hosts mysql redis
docker compose exec mysql mysqladmin ping -h mysql -uroot -proot
docker compose exec redis redis-cli ping
```

O MySQL persiste os dados no volume `mysql_data` e o Redis no volume `redis_data`.
Os serviços se comunicam pela rede interna `mecaniqa`; a API deve usar `mysql:3306` e `redis:6379` como hosts dos serviços.

## Relatório da Sessão: Observabilidade e IoT

O piloto instrumenta o serviço Python com `prometheus-client`, coleta métricas por pod com Prometheus e provisiona no Grafana um dashboard com quatro painéis (CPU, memória, erros e sucessos). O manifesto HPA usa a Metrics API do Kubernetes para CPU/memória; quatro regras de alertas cobrem CPU, memória, taxa de erros e latência p95.

As decisões do brainstorming, thresholds iniciais, runbooks, definições propostas de SLI/SLO/SLA/RTO/RPO e o roteiro completo para Docker/Kubernetes local estão em [docs/observabilidade-e-continuidade.md](./docs/observabilidade-e-continuidade.md). Com o contexto local `docker-desktop`, imagem construída e Metrics API ativa, execute `.\scripts\run-stress-test.ps1` para gerar logs datados em `evidencias/`.

Os thresholds e metas são hipóteses para laboratório: a topologia ainda não demonstra alta disponibilidade, persistência nem recuperação regional, portanto não garante SLA/RTO/RPO de produção.

## Kubernetes

Os manifestos da pasta `k8s/` realizam a implantação da API Java, MySQL e Redis no Kubernetes.

Para verificar os recursos em execução:

```bash
kubectl get pods
kubectl get services
```

## Terraform

A pasta `terraform/` contém a configuração inicial de provisionamento da infraestrutura utilizando Terraform.

O Terraform utiliza o provider Kubernetes para criar e gerenciar o namespace `mecaniqa` no cluster.

Para inicializar e validar a configuração:

```bash
cd terraform
terraform init
terraform validate
terraform plan
```

Para aplicar a configuração:

```bash
terraform apply
```

Após a aplicação, o namespace pode ser verificado com:

```bash
kubectl get namespaces
```
