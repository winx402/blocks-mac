import { copy, type Locale, type PageSlug, locales } from "./site-content";

const screenshots = [
  { src: "/product/settings.jpeg", width: 980, height: 749 },
  { src: "/product/translation.jpeg", width: 678, height: 711 },
  { src: "/product/clipboard.jpeg", width: 1920, height: 292 },
];

function LanguageLinks({ locale, path = "" }: { locale: Locale; path?: string }) {
  return (
    <div className="language-links" aria-label="Language">
      {locales.map((item) => (
        <a
          key={item}
          href={`/${item}${path}/`}
          aria-current={item === locale ? "page" : undefined}
        >
          {copy[item].localeLabel}
        </a>
      ))}
    </div>
  );
}

function Header({ locale }: { locale: Locale }) {
  const content = copy[locale];
  return (
    <>
      <div className="preview-banner">{content.preview}</div>
      <header className="site-header">
        <a className="brand" href={`/${locale}/`}>
          <img src="/product/app-icon.png" alt="" width="36" height="36" />
          <span>{content.brand}</span>
        </a>
        <nav aria-label="Primary">
          <a href={`/${locale}/#features`}>{content.nav.features}</a>
          <a href={`/${locale}/#channels`}>{content.nav.channels}</a>
          <a href={`/${locale}/privacy/`}>{content.nav.privacy}</a>
          <a href={`/${locale}/support/`}>{content.nav.support}</a>
        </nav>
        <LanguageLinks locale={locale} />
      </header>
    </>
  );
}

function Footer({ locale }: { locale: Locale }) {
  const content = copy[locale];
  return (
    <footer>
      <p>© {new Date().getFullYear()} {content.brand} · Pre-release draft</p>
      <div>
        {(Object.keys(content.footer) as PageSlug[]).map((slug) => (
          <a key={slug} href={`/${locale}/${slug}/`}>{content.footer[slug]}</a>
        ))}
      </div>
    </footer>
  );
}

export function MarketingPage({ locale }: { locale: Locale }) {
  const content = copy[locale];
  return (
    <div lang={content.lang}>
      <Header locale={locale} />
      <main>
        <section className="hero">
          <div className="hero-copy">
            <p className="eyebrow">{content.eyebrow}</p>
            <h1>{content.title}</h1>
            <p className="lead">{content.lead}</p>
            <div className="download-panel" id="phase-0">
              <div>
                <strong>{content.betaStatus}</strong>
                <p>{content.betaDetail}</p>
              </div>
              <button type="button" disabled>{content.download}</button>
            </div>
            <ul className="requirements">
              {content.requirements.map((item) => <li key={item}>{item}</li>)}
            </ul>
          </div>
          <figure className="hero-visual">
            <img src={screenshots[0].src} alt={content.screenshots[0]} width={screenshots[0].width} height={screenshots[0].height} />
          </figure>
        </section>

        <section className="section" id="features">
          <p className="section-index">01</p>
          <h2>{content.featuresTitle}</h2>
          <div className="feature-grid">
            {content.features.map((feature) => (
              <article key={feature.title}><h3>{feature.title}</h3><p>{feature.detail}</p></article>
            ))}
          </div>
        </section>

        <section className="section gallery-section">
          <p className="section-index">02</p>
          <h2>{content.screenshotsTitle}</h2>
          <div className="gallery">
            {screenshots.map((image, index) => (
              <figure key={image.src}>
                <img src={image.src} alt={content.screenshots[index]} width={image.width} height={image.height} />
                <figcaption>{content.screenshots[index]}</figcaption>
              </figure>
            ))}
          </div>
        </section>

        <section className="section" id="channels">
          <p className="section-index">03</p>
          <h2>{content.channelsTitle}</h2>
          <p className="section-lead">{content.channelLead}</p>
          <div className="channel-table">
            <article><span>Direct</span><h3>{content.direct}</h3><p>{content.directDetail}</p></article>
            <article><span>Apple</span><h3>{content.store}</h3><p>{content.storeDetail}</p></article>
          </div>
          <a className="text-link" href={`/${locale}/channels/`}>{content.footer.channels} →</a>
        </section>

        <section className="privacy-section" id="privacy">
          <div><p className="section-index">04</p><h2>{content.privacyTitle}</h2></div>
          <div><p>{content.privacyDetail}</p><ul><li>{content.noTelemetry}</li><li>{content.localDiagnostics}</li></ul><a className="text-link" href={`/${locale}/privacy/`}>{content.footer.privacy} →</a></div>
        </section>
      </main>
      <Footer locale={locale} />
    </div>
  );
}

export function InformationPage({ locale, slug }: { locale: Locale; slug: PageSlug }) {
  const content = copy[locale];
  const page = content.pages[slug];
  return (
    <div lang={content.lang}>
      <Header locale={locale} />
      <main className="information-page">
        <p className="eyebrow">{content.brand}</p>
        <h1>{page.title}</h1>
        <p className="lead">{page.intro}</p>
        <div className="information-sections">
          {page.sections.map((section) => <section key={section.title}><h2>{section.title}</h2><p>{section.body}</p></section>)}
        </div>
        <a className="text-link" href={`/${locale}/`}>← {content.brand}</a>
      </main>
      <Footer locale={locale} />
    </div>
  );
}
