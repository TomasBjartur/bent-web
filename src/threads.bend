# Comment pages: a post's comment rows come in thread order (a top-level
# comment, then its replies), and a page shows the first k threads
# (src/handlers.bend: 20). Proved (LAWS.bend comments_page_bounded): the
# rows kept start at most k threads, however many the post has.
import Base

# The rows of the first k threads. flags: for each row, whether it starts
# a thread (a top-level comment).
def threads_take(rows: List<&2, List<&2, String>>, flags: List<&2, Bool>, k: Nat) -> List<&2, List<&2, String>>:
  match rows:
    case Nil{}:
      Nil{}
    case Con{r, t}:
      match flags:
        case Nil{}:
          Nil{}
        case Con{f, fs}:
          match f:
            case True{}:
              match k:
                case 0n:
                  Nil{}
                case 1n+j:
                  Con{r, threads_take(t, fs, j)}
            case False{}:
              Con{r, threads_take(t, fs, k)}
