import { useCallback } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { open, save } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { CONSTRUCTION_DICTIONARY } from "../lib/constants/constructionDictionary";

// Room for a rule with several spoken forms: "эл эм студио, лм студио = LM Studio".
export const MAX_CUSTOM_WORD_LENGTH = 100;

export const normalizeCustomWord = (word: string) =>
  word
    .replace(/[<>"']/g, "")
    .replace(/\s+/g, " ")
    .trim();

const EXPORT_FILE_NAME = "handyru-dictionary.txt";

// Accepts a JSON array of strings or plain text with one entry per line.
const parseEntries = (content: string): string[] => {
  const text = content.replace(/^﻿/, "");
  try {
    const parsed: unknown = JSON.parse(text);
    if (Array.isArray(parsed)) {
      return parsed.filter((item): item is string => typeof item === "string");
    }
  } catch {
    // Not JSON: fall through to line-based parsing.
  }
  return text.split(/\r?\n/);
};

// Appends new unique entries to the existing ones, keeping the existing order.
const mergeEntries = (existing: string[], candidates: string[]) => {
  const known = new Set(existing);
  const added: string[] = [];
  for (const candidate of candidates) {
    if (
      candidate &&
      candidate.length <= MAX_CUSTOM_WORD_LENGTH &&
      !known.has(candidate)
    ) {
      known.add(candidate);
      added.push(candidate);
    }
  }
  return added;
};

export const useCustomWordsIO = (
  customWords: string[],
  setCustomWords: (words: string[]) => void,
) => {
  const { t } = useTranslation();

  const addPreset = useCallback(() => {
    const added = mergeEntries(customWords, CONSTRUCTION_DICTIONARY);
    if (added.length === 0) {
      toast.info(t("settings.advanced.customWords.allPresent"));
      return;
    }
    setCustomWords([...customWords, ...added]);
    toast.success(
      t("settings.advanced.customWords.added", { count: added.length }),
    );
  }, [customWords, setCustomWords, t]);

  const exportWords = useCallback(async () => {
    try {
      const path = await save({
        defaultPath: EXPORT_FILE_NAME,
        filters: [{ name: "Text", extensions: ["txt"] }],
      });
      if (!path) return;
      await writeTextFile(path, customWords.join("\n") + "\n");
      toast.success(t("settings.advanced.customWords.exported"));
    } catch (error) {
      console.error("Failed to export custom words:", error);
      toast.error(t("settings.advanced.customWords.writeError"));
    }
  }, [customWords, t]);

  const importWords = useCallback(async () => {
    try {
      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "Text", extensions: ["txt", "json"] }],
      });
      if (!path) return;
      const content = await readTextFile(path);
      const candidates = parseEntries(content).map(normalizeCustomWord);
      const added = mergeEntries(customWords, candidates);
      if (added.length > 0) {
        setCustomWords([...customWords, ...added]);
      }
      toast.success(
        t("settings.advanced.customWords.imported", { count: added.length }),
      );
    } catch (error) {
      console.error("Failed to import custom words:", error);
      toast.error(t("settings.advanced.customWords.readError"));
    }
  }, [customWords, setCustomWords, t]);

  return { addPreset, exportWords, importWords };
};
