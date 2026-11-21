// Segunda dirección de entrada a la MISMA V2 privada. No duplica estado ni
// credenciales: el Worker original sigue autentificando y procesando PU/R.
export default {
  async fetch(request, env) {
    if (!env?.V2_ORIGIN || typeof env.V2_ORIGIN.fetch !== "function") {
      return new Response("Acceso alternativo temporalmente no disponible", {
        status: 503,
        headers: {"content-type": "text/plain; charset=utf-8", "cache-control": "no-store"}
      });
    }
    // Conservar URL, Origin, Cookie, cuerpo y método. Es imprescindible para
    // /api/login, cookies de sesión y comprobaciones de mismo origen.
    return env.V2_ORIGIN.fetch(request);
  }
};
