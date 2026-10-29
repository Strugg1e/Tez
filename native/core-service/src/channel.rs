#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChannelIdentity {
    pub id: &'static str,
    pub service_slug: &'static str,
    pub windows_service_name: &'static str,
    pub service_display_name: &'static str,
    pub macos_app_bundle_id: &'static str,
    pub macos_service_id: &'static str,
}

#[cfg(not(feature = "development-channel"))]
pub const CHANNEL_IDENTITY: ChannelIdentity = ChannelIdentity {
    id: "production",
    service_slug: "tez-service",
    windows_service_name: "tez_service",
    service_display_name: "Tez Service",
    macos_app_bundle_id: "app.tez",
    macos_service_id: "app.tez.service",
};

#[cfg(all(feature = "development-channel", not(feature = "acceptance-channel")))]
pub const CHANNEL_IDENTITY: ChannelIdentity = ChannelIdentity {
    id: "development",
    service_slug: "tez-service-dev",
    windows_service_name: "tez_service_dev",
    service_display_name: "Tez Development Service",
    macos_app_bundle_id: "app.tez.dev",
    macos_service_id: "app.tez.dev.service",
};

#[cfg(feature = "acceptance-channel")]
pub const CHANNEL_IDENTITY: ChannelIdentity = ChannelIdentity {
    id: "acceptance",
    service_slug: "tez-acceptance-service",
    windows_service_name: "tez_acceptance_service",
    service_display_name: "Tez Acceptance Service",
    macos_app_bundle_id: "app.tez.acceptance",
    macos_service_id: "app.tez.acceptance.service",
};

pub const SERVICE_SLUG: &str = CHANNEL_IDENTITY.service_slug;
pub const WINDOWS_SERVICE_NAME: &str = CHANNEL_IDENTITY.windows_service_name;
pub const SERVICE_DISPLAY_NAME: &str = CHANNEL_IDENTITY.service_display_name;
pub const MACOS_APP_BUNDLE_ID: &str = CHANNEL_IDENTITY.macos_app_bundle_id;
pub const MACOS_SERVICE_ID: &str = CHANNEL_IDENTITY.macos_service_id;

#[cfg(test)]
mod tests {
    use super::CHANNEL_IDENTITY;

    #[test]
    fn compiled_channel_has_a_self_consistent_identity() {
        assert!(!CHANNEL_IDENTITY.id.is_empty());
        if cfg!(feature = "acceptance-channel") {
            assert_eq!(CHANNEL_IDENTITY.service_slug, "tez-acceptance-service");
            assert_eq!(CHANNEL_IDENTITY.macos_service_id, "app.tez.acceptance.service");
            return;
        }
        assert!(CHANNEL_IDENTITY.service_slug.starts_with("tez-service"));
        assert!(CHANNEL_IDENTITY.windows_service_name.starts_with("tez_service"));
        assert!(
            CHANNEL_IDENTITY
                .macos_service_id
                .starts_with(CHANNEL_IDENTITY.macos_app_bundle_id)
        );
    }
}
