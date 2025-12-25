#! /usr/bin/env python

"""Implements calendar logic for scheduled and repeating tasks, and habits.

The goal is to support arbitrary patterns of repetition, and a variety
of different types of report. Eventually, to support syncing with ical
google calendar, and other formats.

For the timing requirements of this application, second-precision is
overkill. We assume that there are exactly 24 hours in a day, 60
minutes in an hour, 60 seconds in a minute, and so on. Technically,
this is wrong because of leap seconds and god knows what else. For the
sake of simplicity, we do a number of calculations as if a second is
always exactly 1/86,400 of a solar day.
"""

from datetime import date, datetime, time, timedelta
from dataclasses import dataclass

import graph
import itertools
import json
import sys

# convenient constants for working with time deltas.
second   = timedelta(seconds = 1)
minute   = timedelta(minutes = 1)
hour     = timedelta(hours = 1)
day      = timedelta(days = 1)
week     = timedelta(weeks = 1)

# define these relative to the start time of the script.
now       = datetime.now()
today     = datetime(now.year, now.month, now.day)
yesterday = today - 1 * day
tomorrow  = today + day

# the length of the day in seconds, for our purposes
ticks = 86400

def debug(*args):
  print(*args, file=sys.stderr)
  return args[-1]

def firstOfMonth(month=today.month, year=today.year):
  """Return the date on which the given month begins."""
  return datetime(year, month, 1)

def startOfWeek(dt):
  """Return the monday which begins the week containing the given day."""
  return dt - timedelta(days=dt.weekday())

def daysOfMonth(month=today.month, year=today.year):
  """Yields all the days of the given month, in order."""
  dt = firstOfMonth(year, month)
  if dt.month == 12:
    end = datetime(dt.year + 1, 1, 1)
  else:
    end = datetime(dt.year, dt.month + 1, 1)
  while dt < end:
    yield dt.day
    dt += 1 * day

def startOfDay(dt):
  """Return the start of the day referred to by the given timestamp."""
  return datetime(dt.year, dt.month, dt.day)

def endOfDay(dt):
  """Return the time just before the start of the next day of the given timestamp."""
  return dt + day - timedelta.resolution

def nextMonth(month, year=today.year):
  """Return the first day of the month after this one."""
  match month + 1:
    case 13: return datetime(year = year + 1, month = 1, day=1)
    case m:  return datetime(year = year, month = m, day = 1)

def lastOfMonth(month, year=today.year):
  """Return the last day of the given month."""
  return nextMonth(month, year) - 1 * day

def firstWeekday(weekday, month=today.month, year=today.year):
  """Return the first instance of the given weekday of the given month."""
  dt = firstOfMonth(month, year)
  while dt.weekday() != weekday:
    dt += 1 * day
  return dt

def lastWeekday(weekday, month=today.month, year=today.year):
  """Return the last instance of the given weekday of the given month."""
  dt = lastOfMonth(month, year)
  while dt.weekday() != weekday:
    dt -= 1 * day
  return dt

def nthWeekday(n, weekday, month=today.month, year=today.year):
  """Return the date of the nth instance of weekday in the given month.

  Negative values of n are relative to the last weekday.
  """
  if n > 0:
    return firstWeekday(weekday, month, year) + (n - 1) * 7 * day
  elif n < 0:
    return lastWeekday(weekday, month, year) - (abs(n) - 1) * 7  * day
  else:
    raise ValueError("`n` cannot be 0")

@dataclass(order=True, frozen=True)
class Interval:
  """The time between two timestamps, or a start timestamp and duration.

  We can do various operations on intervals, including tests for
  containment and intersection, and subdividing in various ways.
  """

  start : datetime
  end : datetime

  @property
  def duration(self):
    """A time delta from the start of the interval.

    This is assumed to be positive.
    """
    return self.end - self.start

  @classmethod
  def fromStartDuration(self, start, duration):
    "Create an interval from a timestamp and duration."
    return Interval(start, start + duration)

  @classmethod
  def fromDate(self, dt, end=None):
    """Construct an interval that spans a date or date range."""
    match end:
      case None: return Interval(startOfDay(dt), startOfDay(dt  + 1 * day))
      case end:  return Interval(startOfDay(dt), startOfDay(end + 1 * day))

  @classmethod
  def sequence(self, start, duration, period=None, phase=None, end=None):
    """Yields an infinite sequence of evenly-spaced intervals."""
    if period is None:
      period = duration

    if phase is None:
      phase = timedelta()

    assert isinstance(start, datetime)
    assert isinstance(duration, timedelta)
    assert isinstance(period, timedelta)
    assert period > timedelta()
    assert duration > timedelta()
    assert phase >= timedelta()
    assert phase < period

    i = start
    match end:
      case None:
        while True:
          yield Interval.fromStartDuration(i + phase, duration)
          i += period
      case end:
        while i <= end:
          yield Interval.fromStartDuration(i + phase, duration)
          i += period

  @classmethod
  def mergeConsecutive(self, intervals):
    """Yields intervals, merging runs of intersecting intervals."""
    next = None
    for i in intervals:
      match next:
        case None:
          next = i
        case next:
          if next.intersects(i):
            next = next.span(i)
          else:
            yield next
            next = i
    if next:
       yield next

  def within(self, timestamp):
    """True if timestamp occurs on or before start, and strictly before end.

    This is so that back-to-events will not supriously register as
    overlapping.
    """
    return self.start <= timestamp <= self.end

  def contains(self, interval):
    return self.within(interval.start) and self.within(interval.end)

  def intersects(self, interval):
    return self.within(interval.start) \
      or self.within(interval.end)     \
      or interval.within(self.start)   \
      or interval.within(self.end)

  def subdivide(self, interval):
    """Subdivide this interval evenly into n subintervals"""
    i = 0
    start = self.start
    n = self.duration // interval
    while start < self.end:
      end = start + interval
      yield Interval(start, end)
      start = end

  def span(self, interval):
    """Return the smallest interval containg self and interval."""
    return Interval(
      min(self.start, interval.start),
      max(self.end, interval.end)
    )

  def intersection(self, interval):
    """Return the portion of two overlapping intervals which intersects.

    This will throw `ValueError` if the two intervals are not overlapping.
    """
    if self.intersects(interval):
      return Interval(
        max(self.start, interval.start),
        min(self.end, interval.end)
      )
    else:
      raise ValueError("Intervals do not Overlap")

  def ordinals(self):
    """An iterator over the julian ordinals which this interval intersects.

    This will always yield at least one value.
    """
    return range(self.start.toordinal(), self.end.toordinal() + 1)

  def days(self):
    return map(
      lambda d: Interval.fromDate(datetime.fromordinal(d)),
      self.ordinals()
    )

@dataclass
class DateSet:
  """Represents when an event can happen.

  We can ask a date set whether or not an arbitrary interval
  intersects it, and we can ask for the set for all the intervals it
  contains which intersect the window.

  A DateSet can be finite or infinite. For finite sets, we can find
  the span (i.e. bounding interval, or the smallest interval that
  contains every interval in the set).
  """

  def intersects(self, window):
    """True if window intersects any interval in the set."""
    try:
      self.intervals(window).__next__()
    except StopIteration:
      return False
    return True

  def is_finite(self):
    """True if this date set is finite."""
    raise NotImplemented

  def span(self):
    """Returns the smallest interval which contains the entire set."""
    raise NotImplemented

  def resolution(self):
    """A hint to the scheduler about the smallest time scales within the set."""
    raise NotImplemented

  def within(self, dt):
    """True if the given dt is part of this set."""
    raise NotImplemented

  def contains(self, window):
    """True if the given window is completely contained by this set."""
    raise NotImplemented

  def intersect(self, window):
    """True if the given window is at least partially contained by this set."""
    raise NotImplemented

  def intervals(self, window):
    """Return an ordered sequence of intervals which intersect `window`."""
    raise NotImplemented

  def completions(self, window, history):
    """Return the set of incomplete intervals according to the completion history..

    A single timestamp within an interval is considered a "completion
    event." Multiple timestamps within an interval are ignored, as are
    timestamps outside of a completion window.
    """
    for i in self.intervals(window):
      yield (i, any(map(i.within, history)))

  def missed(self, window, history):
    return {
      interval
      for (interval, completed)
      in self.completions(window, history) if completed
    }

@dataclass
class Explicit(DateSet):
  """An explicit list of intervals.

  Intersection and containment is defined in terms of `intervals`, returning true if any
  of the subintervals intersects.
  """

  given : List[Interval]

  def __post_init__(self):
    self.given = list(Interval.mergeConsecutive(sorted(self.given)))

  def is_finite(self):
    return True

  def span(self):
    def _spanRec(list):
      match given:
        case []: raise ValueError("Empty")
        case [x]: return x
        case [first, *rest]: return first.span(span_rec(rest))
    return spanRec(self.given)

  def intersects(self, window):
    return any(i.intersects(window) for i in self.intervals(window))

  def within(self, dt):
    return any(i.within(dt) for i in self.given)

  def intervals(self, window):
    for i in Interval.mergeConsecutive(self.given):
      if window.contains(i):
        yield i

@dataclass
class Implicit(DateSet):
  """Base class for types defining intervals via an implicit function
  `within`, which subclasses must implement.

  Certain patterns of repetition are simpler to define implicitly
  rather than explicitly, particularly when used with logical
  operations.

  An implicit function is a predicate that defines a set, where True
  indicates that its argument is within the boundary of the set.

  We can't know exactly which intervals such a set contains, but we
  can sample it down to some arbitrary resolution and then look for
  runs of contigous sub-intervals. As long as the sample points align
  with the actual subintervals, there won't be any artifacts or gaps.

  Given that most real-world institutions divide the day into
  15-minute intervals, this doesn't seem like a huge problem;
  therefore, a 1-minute resolution is the default, as a compromise
  between precision and performance.

  If you needed more precision, you could decrease the resolution, at
  the expense of performance. Conversely, if you need things to run
  faster, and you don't mind losing some precision, increase the
  resolution to 5-, 10-, or 15- minutes.
  """

  def is_finite(self):
    return False

  def contains(self, interval):
    """True if the window is completely contained within this set."""
    return self.within(interval.start) and self.within(interval.end)

  def intervals(self, window, resolution=minute):
    # sample the set at regular intervals which intersect the current window,
    # merging consecutive subintervals in the final result.
    sample_points = Interval.sequence(window.start, resolution)

    yield from Interval.mergeConsecutive(
      filter(
        self.contains,
        itertools.takewhile(
          window.contains,
          sample_points
        )
      )
    )

@dataclass
class Not(Implicit):
  """The logical inverse of the given subexpression.

  E.g. Not(AtTime(12:00, 13:00)) would be all day *except* from noon
  to 13:00. Not(Weekly({5, 6})) would be every day *except* weekends.
  """

  subset : DateSet

  # override here to get expected behaivor for the common ase.
  def contains(self, interval):
    return self.within(interval.start) or self.within(interval.end)

  def within(self, dt):
    return not self.subset.within(dt)

@dataclass
class Compound(Implicit):
  """Base class for date sets which are composed of arbitrary subsets."""
  subsets: set[DateSet]

  def span(self):
    if self.is_finite():
      spans = [span(e) for e in self.subsets]
      starts = [s.start for s in spans]
      ends = [s.end for s in spans]
      return Interval(min(starts), max(ends))
    else:
      raise ValueError("Cannot take the span of a possiby-infinite set.")

@dataclass
class Union(Compound):
  """Take the union of arbitrary subsets.

  If all the subsets are finite, then the union over them is finite.
  """

  def is_finite(self):
    return all(s.is_finite() for s in self.subsets)

  def contains(self, interval):
    return any(s.contains(interval) for s in self.subsets)

  def intersects(self, interval):
    return any(s.intersects(interval) for s in self.subsets)

@dataclass
class Intersection(Compound):
  """Take the intersection of arbitrary subsets.

  If any of the subsets is finite, then the intersection is finite.
  """

  def is_finite(self):
    return any(s.is_finite() for s in self.subsets)

  def contains(self, interval):
    return all(s.contains(interval) for s in self.subsets)

  def intersects(self, interval):
    return all(s.intersects(interval) for s in self.subsets)

@dataclass
class Periodic(Implicit):
  """Repeats evenly at arbitrary time periods."""

  period   : timedelta               # time between intervals
  duration : timedelta = 1 * day     # length of the interval.
  phase    : timedelta = timedelta() # shift start time by up to one period

  def __post_init__(self):
    assert self.duration <= self.period
    assert abs(self.phase) < self.period

  def within(self, dt):
    # convert timestamp to an equivalent timedelta
    since_midnight = dt - datetime(1, 1, 1)
    return (since_midnight - self.phase) % self.period <= self.duration

@dataclass
class AtTime(Implicit):
  """A special-case of Periodic where the period is always exactly one day.

  We don't really need this, but it's more efficient than Periodic,
  and is by far the more common case.

  To schedule an event at multiple times, union multiple AtTime
  instances.
  """
  start    : time
  duration : timedelta

  def __post_init__(self):
    assert self.duration > timedelta()
    # assert (self.start + self.duration) < (1 * day)

  def within(self, dt):
    start = dt.replace(
      hour = self.start.hour,
      minute = self.start.minute,
      second = self.start.second,
      microsecond = self.start.microsecond
    )
    end = start + self.duration
    return start <= dt <= end

@dataclass
class Weekly(Implicit):
  """An arbitrary pattern that repeats every week on particular days.

  Multiple days on a given week can be specified.
  """

  which : set[int]

  def __post_init__(self):
    assert all(0 <= day < 7 for day in self.which)

  # override here to prevent 1-sample gap at end of day, where the
  # ordinal advances to the next day. the *start* of this interval
  # will lie within the set, but the end will not. This redefines
  # "contains" to be a partial intersection, so we can prevent this
  # "off-by-1"-style issue.
  def contains(self, interval):
    return self.within(interval.start)

  def within(self, dt):
    # I'll admit this is rather ugly, but the alternative is a
    # one-minute gap at the end of each event, and possible failure of
    # truly-consecutive intervals to merge.
    return dt.weekday() in self.which

@dataclass
class Monthly(Implicit):
  """Repeats every month on the given days.

  If `month` is given, then repeats yearly during the given month,
  otherwise repeats all year.

  This will not repeat on days that are not part of the month (Feb
  29th on non-leap years, or Apr 31st).

  XXX: allow using negative days to count from the last day of the
  month.

  XXX: allow a fallback when a day doesn't exist.
  """

  days : set[int]
  month : Option[int] = None

  # override here to prevent 1-sample gap at end of day, where the
  # ordinal advances to the next day. the *start* of this interval
  # will lie within the set, but the end will not. This redefines
  # "contains" to be a partial intersection, so we can prevent this
  # "off-by-1"-style issue.
  def contains(self, interval):
    return self.within(interval.start)

  def within(self, dt):
    match self.month:
      case None:  return dt.day in self.days
      case month: return dt.day in self.days and dt.month == month

@dataclass
class NthWeekday(Implicit):
  """Repeats on the nth instance of the given weekday of a month.

  If `month` is given, then repeats yearly during the given month,
  otherwise repeats all year.

  This will not repeat if the nth instance of a given weekday does not
  exist.

  XXX: allow a  fallback when a day doesn't exist.
  """
  n : int
  weekday : int
  month : Option[int] = None

  def within(self, dt):
    match self.month:
      case None: month = dt.month
      case m: month = m

    return Interval.fromDate(
      nthWeekday(self.n, self.weekday, month, dt.year)
    ).within(dt)

@dataclass
class Shift(Implicit):
  """Shift a given DateSet by an arbitrary time offset.

  A positive time-delta shifts events later, while a negative
  offset shifts them earlier.

  e.g. "two days before thanksgiving" -> Offset(-2 * day, NthWeekday(4, 3, 11))
  """

  offset : timedelta
  subset : DateSet

  def is_finite(self):
    return self.subset.is_finite()

  def within(self, dt):
    return self.subset.within(dt - self.offset)

def parseDuration(time):
  """Parse a string into a timedelta.

  This can be a clock format, like 12:00, or a unit like 1m.
  """
  if time.endswith("d"):
    return int(time[:-1]) * day
  elif time.endswith("h"):
    return int(time[:-1]) * hour
  elif time.endswith("m"):
    return int(time[:-1]) * minute
  elif time.endswith("s"):
    return int(time[:-1]) * second
  elif time.endswith("w"):
    return int(time[:-1]) * week
  else:
    raise ValueError(f"Invalid Duration: {time}")


def fromJSON(decoded):
  """Quick-and-dirty DateSet expression DSL evaluator.

  Think of it like s-expressions, with the function name first. Except
  square backets and arguments separated by commas.

  Date-times are always in iso format.
  See parseDuration for time format.
  """
  match decoded:
    case int(i):
      return i
    case str(date):
      try:
        return datetime.fromisoformat(date)
      except ValueError:
        try:
          return time.fromisoformat(date)
        except ValueError:
            return parseDuration(date)
    case ["dates", *dates]:
      return Explicit([Interval.fromDate(fromJSON(d)) for d in dates])
    case ["range", start, end]:
      return Explicit([Interval(fromJSON(start), fromJSON(end))])
    case ["weekly", *days]:
      return Weekly({d for d in days})
    case ["monthly", *days]:
      return Monthly({d for d in days})
    case ["nth", n, wd]:
      return NthWeekday(n, wd)
    case ["++", period]:
      return Periodic(fromJSON(period), 1 * day)
    case ["++", period, duration]:
      return Periodic(fromJSON(period), fromJSON(duration))
    case ["++", period, duration, phase]:
      return Periodic(fromJSON(period), fromJSON(duration), fromJSON(phase))
    case ["@", time_, duration]:
      return AtTime(fromJSON(time_), fromJSON(duration))
    case ["|", *subexprs]:
      return Union([fromJSON(e) for e in subexprs])
    case ["&", *subexprs]:
      return Intersection([fromJSON(e) for e in subexprs])
    case ["~", subexpr]:
      return Not(fromJSON(subexpr))
    case ["except", a, b]:
      return Intersection([fromJSON(a), Not(fromJSON(b))])
    case ["+", a, b]:
      return fromJSON(a) + fromJSON(b)
    case ["-", a, b]:
      return fromJSON(a) - fromJSON(b)
    case ["*", a, b]:
      return fromJSON(a) * fromJSON(b)
    case ["/", a, b]:
      return fromJSON(a) / fromJSON(b)
    case e:
      raise ValueError(f"Illegal date expr: {e}")

@dataclass
class Event:
  """A calendar item, which occurs at a particular (possibly repeating) time.

  @id     - the graph node associated with this item
  @notify - how long before the next occurrence to remind the user.
  """
  id: str
  reminders: list[timedelta]
  when : set[timedelta]

@dataclass
class Task(Event):
  """An event with a completion requirement and history."""
  completed : Set[datetime]

@dataclass
class Habit(Task):
  """A recurring task which progresses towards some goal.
  """
  goal : str
  progress : str

def display_month(highlight, month=today.month, year=today.year):
  """Display a text calendar with matching dates highlighted"""
  days = daysOfMonth(dt.year, dt.month)
  first = days.next()
  print('Mo Tu We Th Fr Sa Su')
  print('   ' * first.weekday(), end = '')
  for d in days:
    cell = f"{d.day:02d} "
    if Interval.fromDate(d).intersects(highlight):
      print(reverse(cell), end='')
    else:
      print(cell, end='')
    if d.weekday() == 6:
      print()
    d += 1 * day
  print()

def partition(pred, seq):
  left = set()
  right = set()
  for i in seq:
    if pred(i):
      right.add(i)
    else:
      left.add(i)
  return (left, right)

def is_scheduled(nodes):
  return filter(lambda id: graph.has(id, 'schedule'), nodes)

def is_unscheduled(nodes):
  return filter(
    lambda id: not graph.has(id, 'schedule'),
    nodes
  )

def is_active():
  return filter(event_is_active())

def is_upcoming(start, end):
  return filter(event_is_upcoming(horizon), events)

def is_due(tasks, deadline=today):
  return filter(task_is_due(deadline), tasks)

def printall(iter):
  for i in iter:
    print(i)

def agenda(type, window):
  events = [
    Event(
      task_gloss(id),
      fromJSON(
        json.load(
          open(graph_datum_path(id, 'schedule'), 'r')
        )
      )
    )
    for id in is_scheduled()
  ]

  print("Schedule")
  match type:
    case "day": day_view(window)
    case "week": week_view(window)
    case "month": month_viw(window)

def display_agenda(events, start=today, end=today + 7 * day):
  pass

def display_completion_calendar(habit, window):
  pass

def display_habit_graph(habitx, window):
  pass


if __name__ == "__main__":
  match sys.argv[1:]:
    case ["is_active"]:
        printall(is_active())
    case ["is_inactive"]:
      is_inactive()
    case ["is_upcoming"]:
      is_upcoming()
    case ["is_upcoming", start, end]:
      is_upcoming(start, end)
    case ["is_due"]:
      is_due()
    case ["is_due", date]:
      is_due(date)
