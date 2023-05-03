import logging
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

def _find_event_by(where: object, events: List[Event]) -> Event | None:
        # print("all events", events)
        event = None
        for e in events:
            passed = True
            keys = e.args_map.keys()

            for attr in where:
                if attr in keys and e.args_map[attr] == where[attr]:
                    # print(f"abstradct event check passed, {e.args_map}")
                    continue
                else:
                     passed = False
            
            if passed:
                return e.args_map