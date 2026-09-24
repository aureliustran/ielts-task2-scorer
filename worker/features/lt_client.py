"""Thin wrapper over a LanguageTool server. Deterministic: no LLM calls, only this network call."""
import os
from dataclasses import dataclass

import language_tool_python
from dotenv import load_dotenv

load_dotenv()

GRA_CATEGORIES = {"GRAMMAR", "PUNCTUATION"}
language_tool_url = os.environ["LANGUAGETOOL_URL"]

@dataclass
class Match:
    category: str
    message: str
    offset: int
    length: int


def _tool(lang: str) -> language_tool_python.LanguageToolPublicAPI:
    return language_tool_python.LanguageTool(
        lang, remote_server=language_tool_url
    )


def check(text: str, lang: str = "en-GB") -> list[Match]:
    """Run LanguageTool over `text`, returning every match with its category id."""
    tool = _tool(lang)
    return [
        Match(
            category=m.category,
            message=m.message,
            offset=m.offset,
            length=m.error_length,
        )
        for m in tool.check(text)
    ]