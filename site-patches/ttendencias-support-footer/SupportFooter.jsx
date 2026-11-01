import React, {useState} from 'react';
import {KOFI_URL, FEEDBACK_EMAIL, cleanSuggestion, buildFeedbackMailto,
        MAX_SUGGESTION_LENGTH, METRIC_EVENTS} from './footer-model.mjs';
import './support-footer.css';

/**
 * Place this after the current Top30 and before the existing Site footer.
 * No new Site, no embedded PayPal/Ko-fi widgets or cookies, no image deletion.
 * Requires the existing Site editor to copy/adapt this component and publish.
 */
export default function SupportFooter({analyticsEnabled = false}) {
  const [suggestion, setSuggestion] = useState('');
  const [notice, setNotice] = useState('');
  const valid = cleanSuggestion(suggestion).length > 0;

  function openEmail(event) {
    event.preventDefault();
    const url = buildFeedbackMailto(suggestion);
    if (!url) return;
    setNotice('Se abrirá tu aplicación de correo. Revisa el mensaje y pulsa Enviar desde allí.');
    // No network request from this Site. The visitor retains editorial control.
    window.location.href = url;
  }

  return (
    <footer className="tt-community" id="participa" aria-label="Participa en TTActualidad">
      <div className="tt-community__grid">
        <section className="tt-community__panel" aria-labelledby="tt-community-donate-heading">
          <p className="tt-community__eyebrow">Apoya este proyecto</p>
          <h2 id="tt-community-donate-heading">¿Te gusta TTActualidad?</h2>
          <p>Si la página te resulta útil, puedes ayudarnos a mantenerla con una
             aportación voluntaria. Sin suscripciones, ventajas ni recompensas.</p>
          <a className="tt-community__button tt-community__button--support"
             href={KOFI_URL} target="_blank" rel="noopener noreferrer"
             data-umami-event={METRIC_EVENTS.donation}>
            Invítanos a un café <span aria-hidden="true">↗</span>
          </a>
          <p className="tt-community__small">
            El enlace abre Ko-fi, un servicio externo con sus propias condiciones.
          </p>
        </section>

        <section className="tt-community__panel" aria-labelledby="tt-community-suggestion-heading">
          <p className="tt-community__eyebrow">Ayúdanos a mejorar</p>
          <h2 id="tt-community-suggestion-heading">¿Tienes una idea o sugerencia?</h2>
          <p>Cuéntanos qué mejorarías, qué función te falta o si has encontrado algún error.</p>
          <form className="tt-community__form" onSubmit={openEmail}>
            <label htmlFor="tt-community-suggestion">Tu mensaje</label>
            <textarea id="tt-community-suggestion" value={suggestion}
                      onChange={event => setSuggestion(event.target.value)}
                      maxLength={MAX_SUGGESTION_LENGTH} rows={3}
                      placeholder="Escribe tu idea o comentario…" />
            <button type="submit" disabled={!valid} className="tt-community__button"
                    data-umami-event={METRIC_EVENTS.feedback}>
              Preparar correo de sugerencia
            </button>
          </form>
          {notice && <p role="status" className="tt-community__small">{notice}</p>}
          <p className="tt-community__small">
            Se abrirá tu correo para que confirmes el envío; la web no almacena el mensaje.
            También puedes escribir directamente a{' '}
            <a href={'mailto:' + FEEDBACK_EMAIL + '?subject=Sugerencia%20TTActualidad'}>
              {FEEDBACK_EMAIL}
            </a>.
          </p>
        </section>
      </div>
      <p className="tt-community__privacy">
        {analyticsEnabled
          ? 'Usamos estadísticas agregadas para conocer las visitas y las interacciones generales, sin guardar el texto de búsquedas ni sugerencias.'
          : 'TTActualidad es un proyecto independiente. Gracias por participar.'}
      </p>
    </footer>
  );
}
