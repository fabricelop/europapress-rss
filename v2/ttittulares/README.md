# TTiTTulares V2

Reconstrucción aislada del motor de noticias para la web privada TTActualidad V2.

- [Auditoría de contratos V1](V1-CONTRACTS-AUDIT.md): qué conservar y qué sustituir.
- [Contrato de datos y arquitectura](DATA-CONTRACT.md): IDs, revisiones, jobs, estados, Chrome efímero, imágenes, decisiones y recibos.
- [Schema JSON](schemas/contract.schema.json): ocho documentos, con cada definición en $defs.
- [Ejemplos sintéticos](examples/sample-bundle.json): objetos enlazados por event_id/revision.
- [Pruebas](test_contract_examples.py): invariantes cruzadas, sin red ni efectos laterales.

**Estado:** contrato diseñado. Todavía no hay radar, cola ejecutable, worker, página Noticias ni automatización de producción. Todo permanece en feature/ttactualidad-v2-clean. V1 y main siguen fuera de este trabajo.