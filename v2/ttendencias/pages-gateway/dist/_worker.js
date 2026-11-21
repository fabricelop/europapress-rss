// Entrada de emergencia en pages.dev. El Worker V2 original atiende TODAS
// las peticiones mediante un vínculo interno, incluida la autenticación.
export default {
  async fetch(request, env) {
    if (!env?.V2_ORIGIN || typeof env.V2_ORIGIN.fetch !== "function") {
      return new Response("Acceso alternativo temporalmente no disponible", {
        status: 503,
        headers: {"content-type": "text/plain; charset=utf-8", "cache-control": "no-store"}
      });
    }
    return env.V2_ORIGIN.fetch(request);
  }
};
