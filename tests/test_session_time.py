from ide_storage.session_time import infer_occurred_at, parse_title_timestamp


def test_title_timestamp_beats_save_time():
    title = "<timestamp>Thursday, Jul 2, 2026, 2:35 PM (UTC-7)</timestamp> Can you figure"
    occurred = infer_occurred_at(title=title, created_at="2026-07-14T05:05:09")
    assert occurred.startswith("2026-07-02")


def test_explicit_occurred_at_wins():
    occurred = infer_occurred_at(
        explicit="2026-06-01T12:00:00",
        title="<timestamp>Thursday, Jul 2, 2026, 2:35 PM (UTC-7)</timestamp>",
        created_at="2026-07-14T05:05:09",
    )
    assert occurred.startswith("2026-06-01")


def test_parse_wrapper():
    dt = parse_title_timestamp("<timestamp>Thursday, Jul 2, 2026, 2:35 PM (UTC-7)</timestamp>")
    assert dt is not None
    assert dt.year == 2026 and dt.month == 7 and dt.day == 2
