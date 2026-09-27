from features.lt_client import GRA_CATEGORIES, check


def test_finds_grammar_error():
    matches = check("He go to school yesterday.", lang="en-GB")
    assert any(m.category in GRA_CATEGORIES for m in matches)

test_finds_grammar_error()