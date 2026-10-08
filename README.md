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

### Board do brainstorming

**Fatos**

- Verificar apenas se um servidor está ligado não revela saturação, erros, latência ou perda de leituras durante os picos das 08:00 e 17:00.
- Observabilidade combina métricas, logs e traces para relacionar o que a aplicação está fazendo com a experiência e os sintomas operacionais.
- O simulador deste piloto expõe métricas Prometheus em `/metrics`: leituras por tipo, falhas elétricas, sensores ativos, temperatura mais recente e duração de processamento dos lotes.
- O Prometheus coleta (scrape) esse endpoint periodicamente e armazena séries temporais. O Grafana consulta o Prometheus como fonte de dados e monta painéis/alertas com PromQL; ele não coleta as métricas diretamente do simulador.

**Questões para a próxima rodada**

- Qual volume de pico, atraso máximo de ingestão e janela de retenção são requisitos reais de produção?
- Quais limites de temperatura, taxa de falhas e latência devem disparar alertas, e quem recebe cada alerta?
- O cluster de produção exigirá alta disponibilidade, armazenamento persistente e autenticação para Prometheus/Grafana?

**Ideias e decisão técnica**

- Adotar o padrão de métricas RED (taxa, erros e duração) junto a indicadores de domínio IoT, começando por coleta a cada 15 segundos.
- Usar rótulos de baixa cardinalidade, como tipo de sensor; não adicionar identificadores únicos de sensores às séries Prometheus.
- Manter Prometheus e simulador acessíveis internamente por Services `ClusterIP`; disponibilizar a interface de consulta localmente com `kubectl port-forward`.
- Tratar o simulador como carga de demonstração, não como teste de capacidade: o dimensionamento final deve ser validado com o volume e os limites de produção.

### Decisão direta: desafio do tráfego

Uma verificação de disponibilidade pode continuar verde enquanto o serviço acumula fila, excede CPU/memória, perde mensagens ou responde lentamente. Nos picos, acompanhar taxa de leituras, falhas, latência de processamento, uso de recursos e disponibilidade permite detectar degradação antes de uma interrupção e localizar o componente responsável. Métricas agregadas também permitem comparar os períodos de pico com o comportamento normal.

### Piloto Kubernetes

O repositório original não continha o simulador Python mencionado no enunciado. Foi criado `iot-simulator/` como carga-base independente, com contadores, gauges e histograma usando `prometheus-client`.

Construa a imagem em um ambiente que o cluster Kubernetes consiga acessar:

```bash
docker build -t mecaniqa-iot-simulator:latest ./iot-simulator
```

Em clusters locais, carregue a imagem no runtime do cluster quando Docker não for compartilhado automaticamente. Em clusters remotos, publique a imagem em um registry e ajuste `image` em `k8s/iot-simulator-deployment.yaml`.

Implante os recursos do piloto:

```bash
kubectl apply -f k8s/iot-simulator-deployment.yaml
kubectl apply -f k8s/iot-simulator-service.yaml
kubectl apply -f k8s/prometheus-config.yaml
kubectl apply -f k8s/prometheus-deployment.yaml
kubectl apply -f k8s/prometheus-service.yaml
kubectl get pods,services
```

Abra Prometheus localmente e confirme `mecaniqa-iot` como `UP` em **Status > Targets**:

```bash
kubectl port-forward service/prometheus 9090:9090
```

Acesse `http://localhost:9090`. Exemplos de consultas PromQL: `rate(mecaniqa_iot_readings_total[5m])`, `rate(mecaniqa_iot_electrical_faults_total[5m])` e `histogram_quantile(0.95, sum by (le) (rate(mecaniqa_iot_batch_processing_seconds_bucket[5m])))`.

O armazenamento configurado neste piloto usa `emptyDir` e é perdido quando o pod é recriado. Para produção, substituir por volume persistente e definir capacidade, autenticação, alertas e política de retenção conforme os requisitos do time.

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
