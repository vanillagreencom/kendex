use ratatui::layout::Rect;

use crate::app::model::Tab;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClickAction {
    SelectTab(Tab),
    SelectRow(usize),
    SelectCostRow(usize),
    PromptPrune(usize),
    PromptFocus(usize),
    ConfirmAction,
    OpenDetail,
    JumpToPaused,
    ToggleNoiseFilter,
    ToggleCompact,
    OpenFilter,
    OpenActivityFilter,
    ActivityExport,
    ClearFilter,
    OpenHelp,
    OpenThemePicker,
    OpenPricingDetail,
    SelectSetting(usize),
    OpenLegend,
    SelectTheme(crate::app::theme::Theme),
    CloseOverlay,
    Quit,
    ScrollUp(ScrollSource),
    ScrollDown(ScrollSource),
    NoOp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollSource {
    Sessions,
    Activity,
    Decisions,
    Conversations,
    Costs,
    DetailRail,
}

#[derive(Debug, Default)]
pub struct HitMap {
    zones: Vec<HitZone>,
}

#[derive(Debug, Clone, Copy)]
struct HitZone {
    rect: Rect,
    action: ClickAction,
    z: u8,
}

impl HitMap {
    pub fn clear(&mut self) {
        self.zones.clear();
    }

    pub fn push(&mut self, rect: Rect, action: ClickAction, z: u8) {
        if rect.width == 0 || rect.height == 0 {
            return;
        }
        self.zones.push(HitZone { rect, action, z });
    }

    #[must_use]
    pub fn hit(&self, col: u16, row: u16) -> Option<ClickAction> {
        self.zones
            .iter()
            .enumerate()
            .filter(|(_, zone)| contains(zone.rect, col, row))
            .max_by_key(|(idx, zone)| (zone.z, *idx))
            .and_then(|(_, zone)| match zone.action {
                ClickAction::NoOp => None,
                action => Some(action),
            })
    }
}

fn contains(rect: Rect, col: u16, row: u16) -> bool {
    col >= rect.x
        && col < rect.x.saturating_add(rect.width)
        && row >= rect.y
        && row < rect.y.saturating_add(rect.height)
}
