from typing  import List
from boa.vyper.event import Event

def _find_event(name: str, events: List[Event]) -> Event | None:
        e_types = [e.event_type.name for e in events]
        # TODO MAY have multiple RevGenerated events based on function called.
        # deposit() emits DEPOSIT + REFERRAL, collect_interest() emits PERFORMANCE + COLLECTOR
        if name in e_types:
            return events[e_types.index(name)]
        else:
            return None
