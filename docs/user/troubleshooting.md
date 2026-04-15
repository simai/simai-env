# Troubleshooting

When something is broken, avoid random clicking. Use this order.

1. `System -> Platform status`
2. `Diagnostics -> Site health check`
3. `Diagnostics -> Configuration check`
4. `SSL -> Certificate status`
5. `Applications -> product status`
6. `Logs -> Website error log`
7. `Logs -> Platform log`

How to interpret sections:

- `Platform status` answers: is the server healthy at all.
- `Site health check` answers: does this site still match its profile contract.
- `Configuration check` answers: does managed metadata and config drift from the expected state.
- `Product status` answers: is Laravel, WordPress, or Bitrix itself in the right lifecycle stage.
- `Logs` answers: what actually failed at runtime.

Use apply actions only after a read-only signal:

- after `Configuration check`, then consider `Repair configuration`,
- after `Optimization plan`, then consider `Apply optimization plan`,
- after status review, then consider `Pause site`, `Resume site`, or product-specific sync actions.
