# MecaniQA Tech: observabilidade, escalabilidade e continuidade

Este documento registra decisões do laboratório e um roteiro reproduzível. Os limites e objetivos abaixo são hipóteses para validação em ambiente local; não são compromissos de produção sem medição, capacidade, persistência, recuperação testada e aprovação contratual.

## Decisões da equipe

### Sessão 1 — métricas e observabilidade

1. **Decisão da equipe — caixa-preta:** introduzir observabilidade significa conseguir inferir taxa, erros, duração, saturação e sintomas de negócio com métricas, logs e traces correlacionáveis. `/healthz` responde somente se o processo está vivo; a equipe também acompanhará sucesso de ingestão, latência, falhas e consumo do cluster.
2. **Decisão da equipe — Prometheus/Grafana:** o simulador Python recebe leituras por `POST /readings`, atualiza contadores/histogramas e expõe `/metrics` na porta 8000. O Prometheus coleta cada pod a cada 15 segundos e armazena séries temporais; o Grafana consulta o Prometheus por PromQL para painéis e alertas. Grafana não faz scrape diretamente do simulador.
3. **Brainstorm guiado — picos das 08h/17h:** checar apenas se o host está ligado não detecta fila, saturação, rejeições, erros nem atraso na ingestão. Nos picos, comparar taxa recebida/processada, erro, p95 e CPU/memória contra o baseline para acionar mitigação antes do impacto nos diagnósticos.
4. **Instrumentação:** usar `prometheus-client`, contadores monotônicos para leituras por resultado/tipo e falhas elétricas, histograma para duração e gauges apenas para valores que podem subir e descer (como temperatura recente e sensores ativos). Rótulos são limitados a `sensor_type` e `result`; IDs de sensores, VINs e outros valores únicos não devem virar labels.

### Sessão 2 — painéis

1. **Decisão da equipe — instrumentação:** usar `prometheus-client`; contar leituras e falhas com `Counter`, medir duração com `Histogram`, expor `/metrics` por HTTP e limitar labels a `sensor_type`/`result`. O Prometheus descobre os endpoints dos pods via Kubernetes, em vez de fazer scrape de um único IP de Service.
2. **Decisão da equipe — visualização:** manter **um dashboard com quatro painéis**, conforme a entrega do enunciado: CPU, memória, taxa percentual de erros e taxa percentual de sucessos. CPU/memória vêm do cAdvisor; resultados vêm dos contadores da aplicação. Os JSONs exportados e provisionados devem corresponder.
3. **Brainstorm guiado — taxa de erros:** comparar a proporção de falhas com taxa e latência permite identificar degradação antes que clientes recebam diagnósticos incompletos. O alerta combina >5% de erros com volume sustentado para evitar reagir a amostras isoladas; deve ser correlacionado com logs e falhas do target.

### Sessão 3 — autoscaling e alertas

1. **Decisão da equipe — HPA:** usar `autoscaling/v2` com métricas de CPU/memória vindas da **Metrics API** do Kubernetes (`metrics-server`), não do Prometheus. Escalar de 2 a 6 réplicas se a média ultrapassar 70% de `requests.cpu` ou 85% de `requests.memory`; toda aplicação precisa declarar requests/limits. Estabilizar scale-down por 300 segundos.
2. **Brainstorm guiado — sucesso do estresse:** comprovar que o Service distribui carga, o HPA aumenta réplicas, os targets do Prometheus seguem `UP`, não há OOM/restarts, erros/p95 voltam ao objetivo após o scale-out e as evidências contêm timestamps, métricas e resultados da carga. Cada alerta deve ser verificado com uma condição controlada; carga saudável não precisa disparar todos.

Quatro regras provisionadas no Grafana usam janelas de 5 minutos e persistência de 5 minutos:

| Alerta | Condição inicial de laboratório | Por que existe |
|---|---|---|
| CPU | Mais de 80% do request atual de 100m (`> 0,08 core`) por pod | Detectar saturação sustentada, mesmo com HPA ativo |
| Memória | Mais de 85% do request de 64 MiB (`> 57.042.534 bytes`) por pod | Detectar crescimento antes do limite de 256 MiB/OOM |
| Erros | Mais de 5% das leituras falhando, com volume superior a 100 leituras/s | Evitar alertar por amostras pequenas |
| Latência | p95 de processamento acima de 800 ms | Detectar degradação que pode anteceder indisponibilidade |

Esses valores são **thresholds provisórios**, não limites “sem falsos positivos” garantidos. O time deve observar pelo menos uma semana de baseline representativa, revisar sazonalidade e ajustar sensibilidade/severidade. As regras ficam em `Normal` na ausência de dados; uma falha de scrape deve ser monitorada separadamente pelo estado dos targets/alerta de indisponibilidade do target.

**Roteamento decidido para o piloto:** CPU/memória são alertas `warning` para Operações/Plataforma; erros/latência são `warning` para Engenharia da Aplicação. O ambiente local não configura e-mail, chat ou pager: o estado de avaliação fica no Grafana e deve ser inspecionado no dashboard/API. Antes de produção, criar contact points, horários de suporte, escalonamento e teste de entrega; alertas críticos de indisponibilidade do target devem ter regra própria.

**Decisão sobre thresholds:** CPU >80% do request de 100m (`>0,08 core`), memória >85% do request de 64 MiB (`>57.042.534 bytes`), erro >5% com mais de 100 leituras elegíveis/s, e p95 >800 ms. Avaliar com janela de 5 minutos e `for: 5m`. Esses limites reduzem ruído por exigir persistência/volume, mas não garantem ausência de falsos positivos; o time precisa aferir baseline e revisar após uma semana.

### Sessão 4 — operação e continuidade

- **Decisão da equipe — Runbooks:** cada runbook registra alerta/impacto, comandos de diagnóstico (`kubectl get/describe/logs/top`), avaliação de requests/limits e eventos, mitigação autorizada (reduzir carga/rollback/scale), confirmação de recuperação e evidências/escalonamento.
- **SLI proposto:** leituras aceitas com sucesso ÷ total de leituras elegíveis recebidas (`success` + erro de processamento), no período. Falhas 5xx contam como indisponibilidade; requisições 4xx inválidas do cliente são marcadas `client_error`, excluídas do denominador e relatadas separadamente. A definição contratual precisa refletir a semântica de negócio e a persistência real.
- **SLO proposto:** 99,95% de disponibilidade mensal para leituras elegíveis. É uma meta operacional com margem sobre a proposta de SLA.
- **SLA proposto:** 99,9% mensal, medido no Service de ingestão e sujeito a exclusões, créditos, horários de suporte e método de cálculo acordados no contrato.
- **Orçamento de indisponibilidade:** 99,9% permite 43,2 minutos em um período de 30 dias ou 8h45m36s em um ano de 365 dias. Uma indisponibilidade regional de 45 minutos ultrapassa o orçamento mensal (e o SLO de 99,95%, cujo orçamento mensal é 21,6 minutos), mas isoladamente não ultrapassa o orçamento anual de SLA de 99,9%. A janela real de cálculo do contrato prevalece.
- **RTO proposto:** até 60 minutos para restaurar o serviço após desastre regional.
- **RPO proposto:** até 5 minutos de leituras aceitas perdidas em uma recuperação.
- **Limite de validade:** RTO/RPO são alvos de projeto, não capacidades demonstradas pelo laboratório. Hoje o simulador é stateless e Prometheus/Grafana usam `emptyDir`; não há fila durável, replicação regional nem procedimento de failover. Não se pode prometer esses alvos nem 99,9% com esta topologia.
- **Brainstorm guiado — região indisponível por 45 minutos:** RTO determina o tempo máximo de restauração; RPO determina a perda máxima de dados, não o tempo offline. Com RTO de 60 minutos, 45 minutos atenderiam o RTO proposto, mas ainda excederiam o orçamento mensal do SLA 99,9% (43,2 minutos). RTO não substitui nem suspende o cálculo de disponibilidade do SLA; aplicam-se apenas as exclusões escritas no contrato.
- **Terminologia:** SLI é a medida; SLO é a meta interna; SLA é o compromisso contratual. RTO mede tempo até restaurar o serviço; RPO mede a janela máxima de dados que pode ser perdida. ITIL é um conjunto de práticas de gestão de serviços, não uma métrica de disponibilidade.

## Runbooks

Em todos os incidentes: registrar início, alertas, namespace, pods e versão; confirmar se o ambiente é laboratório ou produção; evitar reinícios/rollbacks sem salvar eventos e logs; anotar a ação e o resultado. O namespace dos manifestos atuais é `default`.

### 1. CPU acima do limite

1. **Escopo e métricas:** `kubectl get pods -l app=iot-simulator -o wide`; `kubectl top pods -l app=iot-simulator`; `kubectl top nodes`; `kubectl get hpa iot-simulator`; `kubectl describe hpa iot-simulator`.
2. **Container e limites:** `kubectl describe pod <pod>`; `kubectl get deploy iot-simulator -o yaml`; `kubectl logs <pod> -c simulator --since=15m`; para container reiniciado, `kubectl logs <pod> -c simulator --previous`.
3. **Causa/eventos:** `kubectl get events --sort-by=.lastTimestamp`; conferir taxa recebida, throttling, readiness, rollout e targets Prometheus. Confirmar se a média passou de 70% request no HPA e se a regra CPU está >0,08 core por 5m.
4. **Mitigação:** parar/reduzir o gerador; deixar o HPA escalar se há capacidade; scale manual emergencial: `kubectl scale deployment/iot-simulator --replicas=4` (HPA pode reconciliar o número depois). Rollback se coincide com release: `kubectl rollout undo deployment/iot-simulator`; não elevar limits sem verificar `kubectl top nodes`.
5. **Recuperação:** `kubectl rollout status deployment/iot-simulator`; confirmar erro/p95 normalizados, CPU abaixo do threshold e sem restart por 10 minutos; salvar eventos e versão. Remover override manual depois de resolver a causa.

### 2. Memória acima do limite

1. **Escopo:** `kubectl top pods -l app=iot-simulator`; `kubectl top nodes`; `kubectl describe pod <pod>`; `kubectl get events --sort-by=.lastTimestamp`.
2. **Limites e logs:** conferir request 64Mi/limit 256Mi com `kubectl get deploy iot-simulator -o jsonpath='{.spec.template.spec.containers[0].resources}'`; verificar `OOMKilled`/`Evicted`; `kubectl logs <pod> -c simulator --since=15m` e `--previous` se reiniciou.
3. **Causa:** comparar working set com threshold de 57.042.534 bytes e capacidade dos nós; identificar mudança de release/carga. Verificar `kubectl get hpa iot-simulator` para saber se memória provocou scale-out.
4. **Mitigação:** interromper a carga de teste e reduzir consumo; escalar manualmente apenas se nó tiver capacidade. Se regressão após release, `kubectl rollout undo deployment/iot-simulator`. Não aumentar limit como única ação; proteger o nó e investigar OOM.
5. **Recuperação:** observar uso abaixo do threshold, sem OOM/restart e HPA saudável por 10 minutos; guardar logs/events antes de remover réplicas.

### 3. Proporção de erros acima de 5%

1. **Conferir sinal:** PromQL da taxa de erro sobre resultados `success|error`; comparar com `client_error` e validar volume elegível >100 leituras/s por 5m. Verificar target UP e painel de sucesso.
2. **Diagnóstico:** `kubectl get pods -l app=iot-simulator`; `kubectl logs <pod> -c simulator --since=15m`; `kubectl logs <pod> -c simulator --previous`; `kubectl describe pod <pod>` e `kubectl get events --sort-by=.lastTimestamp`. Distinguir 4xx inválido de falha 5xx simulada/real.
3. **Mitigação:** parar gerador de carga; verificar rollout e limites com `kubectl get deploy iot-simulator -o yaml`; se a regressão veio de release, `kubectl rollout undo deployment/iot-simulator`. Reprocessar somente com idempotência e autorização de negócio.
4. **Recuperação:** erro <1% por 10m, taxa de sucesso recuperada, endpoints UP; registrar amostras agregadas, logs e ação tomada sem dados pessoais.

### 4. Latência p95 acima de 800 ms

1. **Confirmar sinal:** calcular p95 com `histogram_quantile(0.95, sum by (le) (rate(mecaniqa_iot_batch_processing_seconds_bucket[5m])))`; comparar com taxa de requests, erros, CPU/memória e HPA.
2. **Diagnóstico:** `kubectl get pods -l app=iot-simulator -o wide`; `kubectl top pods -l app=iot-simulator`; `kubectl describe hpa iot-simulator`; `kubectl describe pod <pod>`; `kubectl logs <pod> -c simulator --since=15m`; revisar readiness, throttling, dependências e rollouts. Distinguir duração interna medida pelo histograma de latência de rede.
3. **Mitigação:** reduzir carga não prioritária; verificar requests/limits e capacidade dos nós; deixar HPA escalar se há capacidade; rollback se regressão de release (`kubectl rollout undo deployment/iot-simulator`). Não aumentar réplicas acima do máximo sem validar dependências e nós.
4. **Recuperação:** p95 <500ms e taxa de sucesso dentro do objetivo por 10m; `kubectl rollout status`, verificar réplicas e alertas resolvidos; registrar causa e prevenção.

## Preparar o laboratório local

### Pré-requisitos

- Windows com Docker Desktop e Kubernetes habilitado, ou Linux com Docker Engine e cluster Kind/Minikube.
- `kubectl`, Docker, Python 3.12+ e acesso à internet para baixar imagens.
- Pelo menos 4 CPUs e 6 GiB de memória disponíveis para Docker/Kubernetes; isso é uma base de laboratório, não dimensionamento de produção.
- O cluster deve estar iniciado e `kubectl config current-context` deve apontar para ele. O daemon Docker precisa estar ativo.

No PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\iot-simulator\requirements.txt
python -m py_compile .\iot-simulator\simulator.py .\iot-simulator\load_test.py
docker build -t mecaniqa-iot-simulator:latest .\iot-simulator
```

No Bash:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r iot-simulator/requirements.txt
python -m py_compile iot-simulator/simulator.py iot-simulator/load_test.py
docker build -t mecaniqa-iot-simulator:latest ./iot-simulator
```

Se o Docker Desktop já estiver instalado, habilite Kubernetes em **Settings > Kubernetes > Enable Kubernetes**, espere o cluster ficar pronto e valide `kubectl config current-context` e `kubectl get nodes`. Alternativamente, instale Minikube e inicie um cluster Docker local:

```powershell
winget install Kubernetes.minikube
minikube start --driver=docker --cpus=4 --memory=6144
minikube addons enable metrics-server
```

No Linux, instale Minikube pelo gerenciador/instruções oficiais da distribuição e execute os mesmos comandos `minikube start` e `minikube addons enable`.

Para Kind, carregue a imagem local: `kind load docker-image mecaniqa-iot-simulator:latest`. Para Minikube: `minikube image load mecaniqa-iot-simulator:latest`. No Docker Desktop Kubernetes, confirme que o cluster enxerga a imagem local. Se o daemon não estiver disponível, inicie Docker Desktop antes de continuar.

Ative/valide o Metrics API para HPA. Em clusters sem addon (por exemplo, alguns clusters Docker Desktop), instale uma versão compatível do metrics-server conforme a documentação do cluster; o manifesto oficial pode ser aplicado com `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`. Confirme `kubectl top nodes`; não aplique opções TLS inseguras fora de um laboratório descartável.

Neste cluster Docker Desktop, o certificado do kubelet não contém o IP do nó como SAN. Se os logs do `metrics-server` mostrarem `cannot validate certificate` e `kubectl top nodes` falhar, é possível usar o seguinte workaround **somente no laboratório local descartável**:

```powershell
$patchFile = Join-Path $env:TEMP "metrics-server-lab-patch.json"
@'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "metrics-server",
          "args": [
            "--cert-dir=/tmp",
            "--secure-port=10250",
            "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
            "--kubelet-use-node-status-port",
            "--metric-resolution=15s",
            "--kubelet-insecure-tls"
          ]
        }]
      }
    }
  }
}
'@ | Set-Content -Path $patchFile
kubectl patch deployment metrics-server -n kube-system --type=strategic --patch-file $patchFile
Remove-Item -LiteralPath $patchFile
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
kubectl top nodes
```

`--kubelet-insecure-tls` desabilita a validação do certificado do kubelet; não use em clusters compartilhados ou de produção.

### Deploy

Crie uma senha de laboratório sem gravá-la no repositório. PowerShell:

```powershell
$GrafanaPassword = Read-Host "Senha admin do Grafana"
kubectl create secret generic grafana-admin --from-literal="password=$GrafanaPassword" --dry-run=client -o yaml | kubectl apply -f -
Remove-Variable GrafanaPassword
```

Bash:

```bash
read -s GRAFANA_PASSWORD
kubectl create secret generic grafana-admin --from-literal="password=$GRAFANA_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
unset GRAFANA_PASSWORD
```

Aplicar os componentes do laboratório:

```bash
kubectl apply -f k8s/iot-simulator-deployment.yaml
kubectl apply -f k8s/iot-simulator-service.yaml
kubectl apply -f k8s/prometheus-rbac.yaml
kubectl apply -f k8s/prometheus-config.yaml
kubectl apply -f k8s/prometheus-deployment.yaml
kubectl apply -f k8s/prometheus-service.yaml
kubectl apply -f k8s/grafana-datasource.yaml
kubectl apply -f k8s/grafana-dashboard.yaml
kubectl apply -f k8s/grafana-alerting.yaml
kubectl apply -f k8s/grafana-deployment.yaml
kubectl rollout status deployment/iot-simulator
kubectl rollout status deployment/prometheus
kubectl rollout status deployment/grafana
kubectl apply -f k8s/iot-simulator-hpa.yaml
kubectl get pods,services,hpa
kubectl top pods
```

Se `kubectl top` falhar, resolva Metrics API antes de considerar o HPA validado. Para acompanhar:

```bash
kubectl get hpa iot-simulator --watch
kubectl port-forward service/prometheus 9090:9090
kubectl port-forward service/grafana 3000:3000
```

Prometheus: `http://localhost:9090` (Status > Targets; confirme todos os pods `mecaniqa-iot` como `UP`). Grafana: `http://localhost:3000`, usuário `admin` e senha do Secret. O port-forward do Service é adequado para inspeção manual; o teste de carga abaixo roda dentro do cluster para passar pelo Service e distribuir requisições entre pods.

### Teste de carga limitado ao laboratório

O endpoint de ingestão não tem autenticação: mantenha-o interno ao cluster. A ferramenta de carga só aceita loopback ou o Service do laboratório. Comece com a taxa baixa, observe nós e pare se houver pressão de recursos.

Teste de conectividade local opcional: `kubectl port-forward service/iot-simulator 8080:8080`, depois `python iot-simulator/load_test.py --duration 30 --rate 25 --concurrency 8`. Esse port-forward é smoke test para um pod selecionado, **não** mede balanceamento entre réplicas.

Teste representativo via Service (a imagem já contém `load_test.py`). O gerador está limitado a 600s, 1000 req/s e 64 conexões, e permite somente o Service do laboratório. A carga alta deve ser progressiva e monitorada:

O orquestrador PowerShell [`scripts/run-stress-test.ps1`](../scripts/run-stress-test.ps1) executa duas fases locais limitadas, acompanha `kubectl get hpa --watch`, pods, `kubectl top pods`, eventos e estado runtime dos alertas Grafana, restaura os valores de ambiente capturados e grava tudo em `evidencias/stress-<timestamp>/`. Rode-o somente com o contexto `docker-desktop`, imagem local construída e Metrics API disponível:

```powershell
.\scripts\run-stress-test.ps1
```

O script aguarda o HPA voltar a 2 réplicas antes da carga e depois da restauração do ambiente. A primeira fase concentra carga CPU e taxa de erro; a segunda injeta memória e latência. As duas são deliberadas e limitadas ao Service `iot-simulator` no cluster local.

Comandos equivalentes para execução manual por fase:

```bash
kubectl set env deployment/iot-simulator CPU_WORK_ITERATIONS=30000 MEMORY_WORK_MB=0 SIMULATED_ERROR_RATE=0.1 PROCESSING_DELAY_SECONDS=0
kubectl run iot-load-error-test --restart=Never --image=mecaniqa-iot-simulator:latest --image-pull-policy=IfNotPresent --command -- python load_test.py --url http://iot-simulator:8080/readings --duration 480 --rate 150 --concurrency 32
```

Use `kubectl get hpa -w`, `kubectl top pods`, `kubectl get pods` e `kubectl get events` em terminais separados; grave suas saídas e timestamps em `evidencias/`. Essa fase pressiona CPU e provoca erros; eles são injetados deliberadamente e fazem o gerador reportar requisições não aceitas.

Para validar especificamente a regra de latência (a injeção espera até 2 segundos e é **somente para teste local**), use uma execução separada sem taxa de erro, que mede o atraso artificial dentro do histograma:

```bash
kubectl set env deployment/iot-simulator CPU_WORK_ITERATIONS=100 MEMORY_WORK_MB=80 SIMULATED_ERROR_RATE=0 PROCESSING_DELAY_SECONDS=0.9
kubectl run iot-load-latency-test --restart=Never --image=mecaniqa-iot-simulator:latest --image-pull-policy=IfNotPresent --command -- python load_test.py --url http://iot-simulator:8080/readings --duration 480 --rate 50 --concurrency 64
```

`MEMORY_WORK_MB=80` força o uso acima do request de memória de 64Mi por réplica, sem ultrapassar o limit de 256Mi; confirme os dados reais com `kubectl top pods`.

As regras avaliam a cada minuto e usam `for: 5m`; aguarde tempo suficiente para que o estado seja `Firing`, registre-o via API/UI do Grafana e depois confirme `Resolved`. As cargas 480s permitem escala inicial e persistência do alerta; valide o resultado real em vez de presumir que o alerta disparou. Enquanto testar, pare caso o nó se aproxime de pressão/OOM, a API deixe de responder ou a taxa de falha ultrapasse o esperado.

Limpe os pods de carga e restaure os valores originais ao final (inclusive em caso de falha):

```bash
kubectl delete pod iot-load-error-test iot-load-latency-test --ignore-not-found
kubectl set env deployment/iot-simulator CPU_WORK_ITERATIONS=100 MEMORY_WORK_MB=0 SIMULATED_ERROR_RATE=0 PROCESSING_DELAY_SECONDS=0
kubectl rollout status deployment/iot-simulator
kubectl get hpa iot-simulator
```

O scale-down do HPA tem estabilização de 300s; aguarde o retorno às duas réplicas antes de considerar o laboratório limpo. Não use esses valores de injeção em produção.

## Limitações antes de produção

- Prometheus usa `emptyDir`: perderá séries após recriação. Grafana provisiona dashboards/alertas por ConfigMap, mas ainda requer política de persistência/backup de estado, autenticação forte, TLS e rede controlada.
- O scrape cAdvisor depende de acesso RBAC a `nodes/proxy`; revise e restrinja permissões conforme a plataforma e use a integração de métricas suportada pelo cluster.
- O HPA precisa de Metrics API operacional e requests realistas; memória pode não ser bom sinal de carga para toda aplicação.
- O simulador valida o caminho de métricas e autoscaling, não persistência, fila, idempotência, processamento real de diagnóstico nem recuperação regional.
- Antes de afirmar SLA/RTO/RPO, implementar storage durável e replicação, backups/restores e failover regional; executar DR game days cronometrados e medir perda de dados.
