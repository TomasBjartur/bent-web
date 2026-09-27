# SPEC: who may do what.
#
# Human-owned. Code may import this file but must never redefine or weaken
# it. Every change here is a security decision and must be called out in the
# commit message. LAWS.bend proves sanity properties of this policy (so a
# mistake here is likely to break one of them).
#
# The policy decides from Facts: what the server loaded about the request.
# Facts are not trusted just because they are here: the write effect
# (src/db.c) re-checks every fact against the database inside the write
# transaction before acting.
import Base

# VOCABULARY
# ----------

type Principal is Data:
  Anon{}
  User{id: U32}

type Role is Data:
  Owner{}
  Author{}

# A post as loaded: its id, the blog it belongs to, and whether it is public.
type PostInfo is Data:
  PostInfo{id: U32, blog: U32, published: Bool}

# who: the session's principal. blog: the blog the request is about.
# role: who's role in that blog (None if not a member).
# post: the post the request is about, if any.
type Facts is Data:
  Facts{who: Principal, blog: U32, role: Maybe<&2, Role>, post: Maybe<&2, PostInfo>}

type Action is Data:
  CreateBlog{}
  EditBlog{blog: U32}
  DeleteBlog{blog: U32}
  AddAuthor{blog: U32, user: U32}
  RemoveAuthor{blog: U32, user: U32}
  CreatePost{blog: U32}
  EditPost{post: U32}
  PublishPost{post: U32}
  DeletePost{post: U32}
  ReadPost{post: U32}
  ReadBlogAdmin{blog: U32}
  LikePost{post: U32}
  CommentPost{post: U32}
  # author: the comment's author as loaded; the write re-checks it (the
  # delete only matches a comment by that author on that post).
  DeleteComment{post: U32, comment: U32, author: U32}
  UploadImage{post: U32}

# PREDICATES
# ----------

# A signed-in user with a real id (0 is never a user).
def is_user(p: Principal) -> Bool:
  match p:
    case Anon{}:
      False{}
    case User{+id}:
      U32.is_ne(id, 0)

def user_id(p: Principal) -> U32:
  match p:
    case Anon{}:
      0
    case User{id}:
      id

def is_owner(r: Maybe<&2, Role>) -> Bool:
  match r:
    case None{}:
      False{}
    case Some{x}:
      match x:
        case Owner{}:
          True{}
        case Author{}:
          False{}

def is_member(r: Maybe<&2, Role>) -> Bool:
  match r:
    case None{}:
      False{}
    case Some{x}:
      True{}

# The request is about blog b, and who is a user who owns it.
def owner_of(+f: Facts, +b: U32) -> Bool:
  match f:
    case Facts{+who, +blog, +role, +post}:
      Bool.and(is_user(who), Bool.and(U32.is_eq(blog, b), is_owner(role)))

# The request is about blog b, and who is a user who owns it or writes for it.
def member_of(+f: Facts, +b: U32) -> Bool:
  match f:
    case Facts{+who, +blog, +role, +post}:
      Bool.and(is_user(who), Bool.and(U32.is_eq(blog, b), is_member(role)))

# The loaded post is post p and belongs to the blog the request is about.
def post_is(+f: Facts, +p: U32) -> Bool:
  match f:
    case Facts{+who, +blog, +role, +post}:
      match post:
        case None{}:
          False{}
        case Some{+x}:
          match x:
            case PostInfo{+id, +pb, +pub}:
              Bool.and(U32.is_eq(id, p), U32.is_eq(pb, blog))

# The loaded post is post p and is published.
def post_public(+f: Facts, +p: U32) -> Bool:
  match f:
    case Facts{+who, +blog, +role, +post}:
      match post:
        case None{}:
          False{}
        case Some{+x}:
          match x:
            case PostInfo{+id, +pb, +pub}:
              Bool.and(U32.is_eq(id, p), pub)

def facts_blog(+f: Facts) -> U32:
  match f:
    case Facts{+who, +blog, +role, +post}:
      blog

def facts_who(+f: Facts) -> Principal:
  match f:
    case Facts{+who, +blog, +role, +post}:
      who

# May write post p: a member of the post's blog.
def can_write_post(+f: Facts, +p: U32) -> Bool:
  Bool.and(member_of(f, facts_blog(f)), post_is(f, p))

# THE WRITE BUDGET
# ----------------
# SECURITY DECISION (2026-09-27): a user writes at most writes_per_minute()
# times a minute (likes, comments, saves, posts, blogs, authors, images;
# not typing, which syncs with its own limits). Without it one account
# could flood the database or keep a server busy re-rendering. spent: the
# user's writes in the current minute, as loaded; the write effect
# re-checks and counts it inside its transaction (src/c/db_core.h
# WRITE_BUDGET_MAX, which must be this number).
def writes_per_minute() -> U32:
  30

def within_budget(+spent: U32) -> Bool:
  U32.is_lt(spent, writes_per_minute())

# THE POLICY
# ----------

def permitted(+f: Facts, a: Action) -> Bool:
  match a:
    # Any signed-in user may create a blog (and becomes its owner).
    case CreateBlog{}:
      is_user(facts_who(f))
    # Only the owner edits or deletes a blog, or manages its authors.
    case EditBlog{+b}:
      owner_of(f, b)
    case DeleteBlog{+b}:
      owner_of(f, b)
    case AddAuthor{+b, +u}:
      Bool.and(owner_of(f, b), U32.is_ne(u, 0))
    # The owner cannot remove themself (a blog always has its owner).
    case RemoveAuthor{+b, +u}:
      Bool.and(owner_of(f, b), U32.is_ne(u, user_id(facts_who(f))))
    # Members write posts in their blog.
    case CreatePost{+b}:
      member_of(f, b)
    case EditPost{+p}:
      can_write_post(f, p)
    case PublishPost{+p}:
      can_write_post(f, p)
    case DeletePost{+p}:
      can_write_post(f, p)
    # Anyone reads a published post; members also read drafts.
    case ReadPost{+p}:
      Bool.or(post_public(f, p), can_write_post(f, p))
    case ReadBlogAdmin{+b}:
      member_of(f, b)
    # Readers take part: any signed-in user likes or comments on a
    # published post (never a draft).
    case LikePost{+p}:
      Bool.and(is_user(facts_who(f)), post_public(f, p))
    case CommentPost{+p}:
      Bool.and(is_user(facts_who(f)), post_public(f, p))
    # A comment is removed by its author, or by a member of the post's blog
    # (moderation).
    case DeleteComment{+p, +c, +a}:
      Bool.and(is_user(facts_who(f)), Bool.and(post_is(f, p), Bool.or(Bool.and(U32.is_ne(a, 0), U32.is_eq(a, user_id(facts_who(f)))), can_write_post(f, p))))
    # Images for a post are added by those who may write it.
    case UploadImage{+p}:
      can_write_post(f, p)
