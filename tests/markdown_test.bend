import Base
import ../spec/markup.bend as M
import ../src/markdown.bend as Md

def r(+s: String) -> String:
  M.html(Md.render(s), "")

def msg(ok: Bool, name: String, got: String, want: String) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ (name ++ ("\n  got  " ++ (got ++ ("\n  want " ++ want))))

def check(name: String, +got: String, +want: String) -> IO(Unit):
  IO.print(msg(String.eq(got, want), name, got, want))

def main() -> IO(Unit):
  do IO<Unit>:
    check("paragraph", r("hello"), "<p>hello</p>")
    check("two paragraphs", r("a\n\nb"), "<p>a</p><p>b</p>")
    check("soft break becomes a space", r("a\nb"), "<p>a b</p>")
    check("strong", r("a **b** c"), "<p>a <strong>b</strong> c</p>")
    check("em star", r("*x*"), "<p><em>x</em></p>")
    check("em underscore", r("_x_"), "<p><em>x</em></p>")
    check("code", r("`a<b`"), "<p><code>a&lt;b</code></p>")
    check("nested", r("**a *b* c**"), "<p><strong>a <em>b</em> c</strong></p>")
    check("link", r("[site](https://ex.com/a?b=c)"), "<p><a href=\"https://ex.com/a?b=c\" rel=\"nofollow noopener ugc\">site</a></p>")
    check("relative link", r("[home](/b/x)"), "<p><a href=\"/b/x\" rel=\"nofollow noopener ugc\">home</a></p>")
    check("javascript link stays text", r("[x](javascript:alert(1))"), "<p>[x](javascript:alert(1))</p>")
    check("protocol-relative link stays text", r("[x](//evil.com)"), "<p>[x](//evil.com)</p>")
    check("quote in url stays text", r("[x](/a\"onmouseover=\"alert(1))"), "<p>[x](/a&quot;onmouseover=&quot;alert(1))</p>")
    check("data url stays text", r("[x](data:text/html,<script>)"), "<p>[x](data:text/html,&lt;script&gt;)</p>")
    check("raw html escaped", r("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
    check("img onerror escaped", r("<img src=x onerror=alert(1)>"), "<p>&lt;img src=x onerror=alert(1)&gt;</p>")
    check("unclosed strong literal", r("**open"), "<p>**open</p>")
    check("escaped star", r("\\*not em\\*"), "<p>*not em*</p>")
    check("h2", r("## Title <x>"), "<h2>Title &lt;x&gt;</h2>")
    check("h1 becomes h2", r("# Top"), "<h2>Top</h2>")
    check("h3", r("### Sub"), "<h3>Sub</h3>")
    check("list", r("- a\n- **b**"), "<ul><li>a</li><li><strong>b</strong></li></ul>")
    check("numbered list", r("1. one\n2. two"), "<ol><li>one</li><li>two</li></ol>")
    check("quote", r("> said\n> this"), "<blockquote><p>said this</p></blockquote>")
    check("fenced code", r("```\n<script>\n  x\n```"), "<pre><code>&lt;script&gt;<br>  x</code></pre>")
    check("tab in code", r("```\n\tx\n```"), "<pre><code>    x</code></pre>")
    check("unclosed fence", r("```\ncode"), "<pre><code>code</code></pre>")
    check("mixed blocks", r("intro\n- a\n\n## H\ntext"), "<p>intro</p><ul><li>a</li></ul><h2>H</h2><p>text</p>")
    check("empty", r(""), "")
    check("control chars dropped", r("a" ++ SCon{Chr{1}, "b"}), "<p>ab</p>")
