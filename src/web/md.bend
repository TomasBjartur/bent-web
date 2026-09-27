# The Markdown renderer (src/markdown.bend) for the browser: the editor's
# WYSIWYG mode shows exactly the HTML the server will publish, made by the
# same code, whose output is provably allowed markup (spec/markup.bend).
import Base
import ../markdown.bend as Md
import ../../spec/markup.bend as M

def html_of(s: String) -> String:
  M.html(Md.render(s), "")
