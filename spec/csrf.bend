# SPEC: which requests may change state.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message.
#
# A state-changing request must carry Sec-Fetch-Site: same-origin. Browsers
# set this header themselves and pages cannot forge it, so a cross-site form
# or fetch can never change state. (The session cookie is also
# SameSite=Strict: two independent defenses.) Clients that send no
# Sec-Fetch-Site cannot change state at all; every current browser sends it.
import Base

def csrf_ok(+site: Maybe<&2, String>) -> Bool:
  match site:
    case None{}:
      False{}
    case Some{+s}:
      String.eq(s, "same-origin")
