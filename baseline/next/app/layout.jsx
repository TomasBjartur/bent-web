import "./app.css";

export default function Layout({ children }) {
  return (
    <html lang="en">
      <body>
        <a className="skip" href="#main">Skip to content</a>
        <header className="top">
          <div className="wrap wide">
            <a className="brand" href="/">slop<span>stack</span></a>
            <nav>
              <a href="/search" className="hide-sm">Search</a>
              <a href="/login">Log in</a>
              <a className="btn primary" href="/signup">Start writing</a>
            </nav>
          </div>
        </header>
        <main id="main"><div className="wrap">{children}</div></main>
      </body>
    </html>
  );
}
