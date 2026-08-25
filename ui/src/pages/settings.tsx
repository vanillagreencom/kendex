import { MinusIcon, PlusIcon } from "lucide-react";
import { useEffect, useState } from "react";
import type { Appearance } from "@/bindings";
import { commands, ZOOM } from "@/bindings";
import { AccountSection } from "@/components/account-section";
import { PageHeader } from "@/components/page-header";
import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { SETTINGS_SUBTITLE } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useSettingsStore } from "@/stores/settings";
import { zoom } from "@/stores/zoom";

const THEME_LABELS: Record<Appearance, string> = {
  system: "System",
  light: "Light",
  dark: "Dark",
};

export function SettingsPage() {
  const { settings, onScreen, setAppearance } = useSettingsStore();
  const [version, setVersion] = useState<string | null>(null);

  useEffect(() => {
    void commands.appVersion().then(setVersion);
  }, []);

  const percent = onScreen();

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

          <AccountSection />

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
