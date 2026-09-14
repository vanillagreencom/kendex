import { MinusIcon, PlusIcon } from "lucide-react";
import { useEffect, useState } from "react";
import type { Appearance } from "@/bindings";
import { commands, LEGAL, ZOOM } from "@/bindings";
import { AccountSection } from "@/components/account-section";
import { ExternalLink } from "@/components/external-link";
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
import { Switch } from "@/components/ui/switch";
import { SETTINGS_ABOUT_HELP, SETTINGS_ZOOM_HELP } from "@/lib/copy";
import {
  COMMIT_OFFER_SETTING_DESCRIPTION,
  COMMIT_OFFER_SETTING_LABEL,
  GIT_PROJECTS_SECTION,
} from "@/lib/copy-commit-offer";
import { SETTINGS_SUBTITLE } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useSettingsStore } from "@/stores/settings";
import { acceptedSummary, useTermsStore } from "@/stores/terms";
import { zoom } from "@/stores/zoom";

const THEME_LABELS: Record<Appearance, string> = {
  system: "System",
  light: "Light",
  dark: "Dark",
};

export function SettingsPage() {
  const { settings, onScreen, setAppearance, setCommitOffer } =
    useSettingsStore();
  // Null until the read answers; after that the read's own answer, so a
  // version the app could not ask for says so instead of sitting on the
  // ellipsis a still-loading read wears.
  const [version, setVersion] = useState<Awaited<
    ReturnType<typeof commands.appVersion>
  > | null>(null);
  const terms = useTermsStore((s) => s.state);
  const loadTerms = useTermsStore((s) => s.load);

  useEffect(() => {
    void commands.appVersion().then(setVersion);
    // The record is written on first run and on an accept, both of which
    // can have happened since this page last read it — in this window or
    // in a terminal.
    void loadTerms();
  }, [loadTerms]);

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
            <SettingRow label="Zoom" description={SETTINGS_ZOOM_HELP}>
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

          <Section title={GIT_PROJECTS_SECTION}>
            <SettingRow
              label={COMMIT_OFFER_SETTING_LABEL}
              description={COMMIT_OFFER_SETTING_DESCRIPTION}
              htmlFor="commit-offer"
            >
              <Switch
                id="commit-offer"
                checked={(settings?.["commit-offer"] ?? "ask") === "ask"}
                onCheckedChange={(on) =>
                  void setCommitOffer(on ? "ask" : "off")
                }
              />
            </SettingRow>
          </Section>

          <AccountSection />

          <Section title="About">
            <SettingRow
              label={
                <span className="flex items-baseline gap-2">
                  Version
                  <span className="font-mono text-xs font-normal text-muted-foreground">
                    {version === null
                      ? "…"
                      : version.status === "ok"
                        ? version.data
                        : "unavailable"}
                  </span>
                </span>
              }
              role={version?.status === "error" ? "alert" : undefined}
              description={
                version?.status === "error"
                  ? `kendex couldn't read its own version: ${version.error}`
                  : SETTINGS_ABOUT_HELP
              }
            />
            <SettingRow
              label={
                <span className="flex items-baseline gap-2">
                  Terms
                  <span className="font-mono text-xs font-normal text-muted-foreground">
                    {acceptedSummary(terms)}
                  </span>
                </span>
              }
              description="What you accepted, and when. The record is on this computer only."
            >
              <div className="flex gap-4 text-sm">
                <ExternalLink url={LEGAL.termsUrl}>Terms</ExternalLink>
                <ExternalLink url={LEGAL.privacyUrl}>Privacy</ExternalLink>
              </div>
            </SettingRow>
          </Section>
        </div>
      </div>
    </div>
  );
}
