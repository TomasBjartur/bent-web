import "./app.css";

export default function Layout({ children }) {
  return (
    <html lang="en">
      <body>
        <header>
          <a href="/" className="brand">bent</a>
          <nav><a href="/login">Log in</a></nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
