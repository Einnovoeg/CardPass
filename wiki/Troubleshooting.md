# Troubleshooting

## No readers

- Check the reader is plugged in: `system_profiler SPUSBDataType | grep -i -A2 card`
- Check Console for `CardPass` logs.

## No data

- Some cards need a PIN or use a custom applet. File an issue with the ATR.

## Auto-type does nothing

- Use `⌘V` (always works).
- To enable auto-type, grant the permission and relaunch the app.

## Multiple readers

- When two readers are connected, a dropdown appears. Choose `Auto (any reader)` or a specific reader.
- The selected reader’s card is shown in `Card Data` and in `Advanced`.

## Other issues

Please file an issue with the reader name, ATR, and log output:

```bash
log stream --predicate 'process == "CardPass"'
```
