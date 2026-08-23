import { MinusIcon, PlusIcon } from "lucide-react";
import { useEffect, useState } from "react";
import type { Appearance } from "@/bindings";
import { commands, ZOOM } from "@/bindings";
import { AccountSection } from "@/components/account-section";
import { PageHeader } from "@/components/page-header";
import { RecordedDecisions } from "@/components/recorded-decisions";
import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { SAFETY_HELP, SAFETY_SECTION_EXPLAINER } from "@/lib/copy-safety";
import { SETTINGS_SUBTITLE } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useSettingsStore } from "@/stores/settings";
import { zoom } from "@/stores/zoom";

// How cautious the safety check is, said without numbers on the dial.
const SAFETY_LEVELS = {
  strict: { "warn-below": 90, "block-below": 75 },
  balanced: { "warn-below": 80, "block-below": 60 },
  lenient: { "warn-below": 65, "block-below": 40 },
} as const;

type SafetyLevel = keyof typeof SAFETY_LEVELS;

const THEME_LABELS: Record<Appearance, string> = {
  system: "System",
  light: "Light",
  dark: "Dark",
};

const SAFETY_LABELS: Record<SafetyLevel, string> = {
  strict: "Strict",
  balanced: "Balanced",
  lenient: "Lenient",
};

function safetyLevelOf(warn: number, block: number): SafetyLevel | "custom" {
  for (const [name, t] of Object.entries(SAFETY_LEVELS)) {
    if (t["warn-below"] === warn && t["block-below"] === block)
      return name as SafetyLevel;
  }
  return "custom";
}

export function SettingsPage() {
  const { settings, onScreen, setAppearance, setSafety } = useSettingsStore();
  const [version, setVersion] = useState<string | null>(null);

  useEffect(() => {
    void commands.appVersion().then(setVersion);
  }, []);

  const percent = onScreen();
  const safety = settings?.safety ?? SAFETY_LEVELS.balanced;
  const level = safetyLevelOf(safety["warn-below"], safety["block-below"]);

  return (
    <div>
      <PageHeader title="Settings" subtitle={SETTINGS_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-10", CONTENT_WIDTH)}>
          <Section title="Appearance">
            <SettingRow
              label="Theme"
              description="Follows your system by default."
            >
              <Select
                value={settings?.appearance ?? "system"}
                onValueChange={(value) =>
                  void setAppearance(value as Appearance)
                }
              >
                <SelectTrigger className="w-40">
                  <SelectValue>
                    {(value: Appearance) => THEME_LABELS[value]}
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="system">System</SelectItem>
                  <SelectItem value="light">Light</SelectItem>
                  <SelectItem value="dark">Dark</SelectItem>
                </SelectContent>
              </Select>
            </SettingRow>
            <SettingRow
              label="Zoom"
              description="How large everything draws. Ctrl with + or - changes it from anywhere, and Ctrl 0 returns to 100%. On a Mac, Cmd does the same."
            >
              <div className="flex w-40 items-center justify-end gap-2">
                <Button
                  variant="outline"
                  size="icon-sm"
                  aria-label="Zoom out"
                  disabled={percent <= ZOOM.min}
                  onClick={() => zoom.step(-ZOOM.step)}
                >
                  <MinusIcon />
                </Button>
                <span className="w-11 text-center font-mono text-xs tabular-nums text-muted-foreground">
                  {percent}%
                </span>
                <Button
                  variant="outline"
                  size="icon-sm"
                  aria-label="Zoom in"
                  disabled={percent >= ZOOM.max}
                  onClick={() => zoom.step(ZOOM.step)}
                >
                  <PlusIcon />
                </Button>
              </div>
            </SettingRow>
          </Section>

          <Section title="Safety check" description={SAFETY_SECTION_EXPLAINER}>
            <SettingRow label="How cautious" description={SAFETY_HELP}>
              <Select
                value={level === "custom" ? "balanced" : level}
                onValueChange={(value) => {
                  const t = SAFETY_LEVELS[value as SafetyLevel];
                  void setSafety(t["warn-below"], t["block-below"]);
                }}
              >
                <SelectTrigger className="w-40">
                  <SelectValue>
                    {(value: SafetyLevel) => SAFETY_LABELS[value]}
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="strict">Strict</SelectItem>
                  <SelectItem value="balanced">Balanced</SelectItem>
                  <SelectItem value="lenient">Lenient</SelectItem>
                </SelectContent>
              </Select>
            </SettingRow>
          </Section>

          <AccountSection />

          <RecordedDecisions />

          <Section title="About">
            <SettingRow
              label={
                <span className="flex items-baseline gap-2">
                  Version
                  <span className="font-mono text-xs font-normal text-muted-foreground">
                    {version ?? "…"}
                  </span>
                </span>
              }
              description="kendex keeps your AI coding tools in sync."
            />
          </Section>
        </div>
      </div>
    </div>
  );
}
