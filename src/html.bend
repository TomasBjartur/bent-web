# HTML text escaping. The escaper itself lives in spec/html.bend (it defines
# how text becomes HTML, and spec/markup.bend's serializer uses it); its
# safety law, html_esc_safe, is proved in PROOF.bend.
import Base
import ../spec/html.bend as Spec

# Escapes s in front of rest.
def esc(s: String, rest: String) -> String:
  Spec.esc(s, rest)
