# Restauración segura de mecanismos TT

Este directorio separa **mecanismos** de **estado vivo** para TTiTTulares y TTendencias.

## Referencia estable

- Backup: `BackupMecanismosTT20261007-1827`
- Commit base: `a3d1d3c619cc44c50fb65fb1ad9ec429703360ff`

La rama de backup conserva el repositorio completo como referencia histórica, pero la restauración normal **no restaura el repositorio completo**. `restore_mechanisms.py` selecciona exclusivamente los archivos permitidos por `mechanism-backup-policy.json`.

## Qué se protege

No se restauran colas, históricos, decisiones, estados de Telegram, publicaciones, imágenes generadas, imágenes de archivo, heartbeats ni triggers. Las exclusiones tienen prioridad sobre cualquier inclusión.

Por tanto, un rollback de mecanismos no debe hacer que vuelvan noticias/tendencias ya procesadas ni borrar decisiones posteriores al backup.

## Uso

Primero revisar siempre:

```bash
python safety/restore_mechanisms.py
```

Eso es un **dry-run** y no modifica archivos.

Restaurar todos los mecanismos permitidos:

```bash
python safety/restore_mechanisms.py --apply
```

Restaurar solo un mecanismo concreto:

```bash
python safety/restore_mechanisms.py --apply --path trends/telegram_bot.py
```

El script nunca hace `git reset`, nunca cambia de rama y nunca elimina archivos. Después de una restauración se revisa el diff y solo entonces se decide si se publica el cambio.
