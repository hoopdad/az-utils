# Portal-friendly KQL queries

These queries are intended to be copied directly into Azure Portal experiences such as Log Analytics, Azure Monitor Logs, and Resource Graph Explorer. They focus on capacity planning scenarios where Resource Graph alone cannot provide the full picture.

## Structure

```text
portal-queries/
├── README.md
├── log-analytics-cpu-memory.kql          # VM metrics via Perf table
├── log-analytics-app-service-metrics.kql # App Service via AzureMetrics
├── log-analytics-sql-metrics.kql         # SQL DB via AzureMetrics
├── insights-metrics-vm.kql               # VM Insights via InsightsMetrics
├── resource-graph-quota-workaround.kql   # Resource density per region
└── resource-graph-reservations-info.kql  # Reservation candidates
```

## Where to run each query

| Query File | Portal Location | Prerequisites |
|---|---|---|
| `log-analytics-cpu-memory.kql` | Azure Portal > Monitor > Logs, or Log Analytics workspace > Logs | VMs sending Perf data through Azure Monitor Agent or Log Analytics Agent |
| `log-analytics-app-service-metrics.kql` | Azure Portal > Monitor > Logs, or Log Analytics workspace > Logs | Diagnostic settings sending App Service metrics to Log Analytics |
| `log-analytics-sql-metrics.kql` | Azure Portal > Monitor > Logs, or Log Analytics workspace > Logs | Diagnostic settings sending SQL metrics to Log Analytics |
| `insights-metrics-vm.kql` | Azure Portal > Azure Monitor > Logs, or a VM Insights workspace | Azure Monitor Agent with VM Insights enabled |
| `resource-graph-quota-workaround.kql` | Azure Portal > Resource Graph Explorer | Reader access on target subscriptions |
| `resource-graph-reservations-info.kql` | Azure Portal > Resource Graph Explorer | Reader access on target subscriptions |

## What's not available in portal KQL

Some capacity-related data is not exposed through KQL in Azure Portal experiences:

- **Quota limits and quota usage** must be checked with `az vm list-usage` or in the Azure Portal at **Subscriptions > Usage + quotas**.
- **Reservation orders and reservation purchases** must be checked in **Cost Management + Billing > Reservations**.

These items cannot be queried through KQL in Log Analytics, Azure Monitor Logs, or Resource Graph Explorer.

## Portal navigation

- **Resource Graph Explorer**: Azure Portal > search for `Resource Graph Explorer`
- **Log Analytics Logs**: Azure Portal > `Monitor` > `Logs`, or open a specific Log Analytics workspace and select `Logs`
- **Quotas**: Azure Portal > `Subscriptions` > select a subscription > `Usage + quotas`
- **Reservations**: Azure Portal > `Cost Management + Billing` > `Reservations`
