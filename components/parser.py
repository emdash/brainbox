import sly
import shedule

def parseDateSet(s):
  tokens = tokenizePattern(s)

  context = {}

  for token in tokens:
    match token:
      case "at": re
        eva
  match tokens:
    case [('DATE', d)]:   return Explicit(Interval.fromDate(d))
    case [('DAY',  d)]:   return Explicit(Interval.fromDayName(d))
    case ['forall', day]:



class Lexer(sly.Lexer):
  """Lexer for DateSet expressions"""

  literals = {
    "from",
    "at",
    "@",
    "to",
    "-",
    "of",
    "every",
    "each",
    "all",
    "and",
    "&&",
    "or",
    "|",
    "except",
    "but",
    "$",
    "(",
    ")",
    "-"
    "|",
    "&",
    "~",
    "++",
    "+",
    "h",
  }

  tokens = {
    DATE,
    ORDINAL,
    CARDINAL,
    DAY,
    U_MONTH,
    U_SECOND,
    U_MINUTE,
    U_HOUR,
    U_DAY,
    U_WEEK,
    U_YEAR
  }

  ignore = ' \t\r\n'

  DATE     = r"\d{4}-\d{2}-\d{2}"
  ORDINAL  = r"\d{1,2}st|nd|rd|th"
  CARDINAL = r"([1-9]\d*)"
  TIME     = r"(d{2})(:\(d{2})(:\d{2})?)?"
  DAY      = r"Mo|Tu|We|Th|Fr|Sa|Su"
  MONTH    = r"Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec"
  MINUS    = r"-"
  PIPE     = r"|"
  TILDE    = r"~"
  AMP      = r"&"
  COMMA    = r","
  LPAREN   = r"\("
  RPARAN   = r"\)"
  SECOND   = r"s(econds?)?"
  U_MINUTE   = r"m(inutes?)?"
  U_HOUR     = r"h(ours?)?"
  U_DAY      = r"d(ays?)?"
  U_WEEK     = r"w(eeks?)?"
  U_YEAR     = r"y(ears?)?"

  def error(self, t):
    print(f"Unexpected token: '{t.value[0]}'")

class Parser(sly.Parser):
  """Parser for DateSet expressions"""
  tokens = Lexer.tokens

  precedence = (
    ('left', PIPE, AMP),
    ('left', TILDE, MINUS),
  )

  def __init__(self):
    pass

  @_('DATE')
  def bareDate(self, p):
    return datetime.fromisoformat(p[0].value)

  @_('TIME')
  def bareTime(self, p):
    return datetime.time(p[0].value)

  @_('bareDate')
  def dateList(self, p):
    return set(p[0])

  @_('bareDate ',' dateList')
  def dateList(self, p):
    return set(p[0]) | p[1]

  @_('dateList')
  def dateSet(self, p):
    return schedule.Explicit(p[0])

  @_('u

if __name__ == "__main__":
  pass
