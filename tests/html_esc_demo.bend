import Base
import ../src/html.bend as Html

def main() -> IO(Unit):
  IO.print(Html.esc("<script>alert(\"x\")</script> & it's" ++ SCon{Chr{1}, SCon{Chr{7}, "ok"}}, ""))
