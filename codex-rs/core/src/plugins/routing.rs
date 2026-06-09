#![allow(dead_code)]

use std::collections::HashSet;

use codex_app_server_protocol::AuthMode;

use crate::connectors::AppInfo;
use crate::plugins::PluginCapabilitySummary;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PluginRoute {
    Default,
    AppPreferred,
    AppUnavailable,
    McpPreferred,
}

pub(crate) fn route_for_plugin(
    plugin: &PluginCapabilitySummary,
    available_connectors: &[AppInfo],
    auth_mode: Option<AuthMode>,
) -> PluginRoute {
    if !is_dual_surface_plugin(plugin) {
        return PluginRoute::Default;
    }

    if auth_mode.is_some_and(AuthMode::has_chatgpt_account) {
        return if plugin_has_available_connector(plugin, available_connectors) {
            PluginRoute::AppPreferred
        } else {
            PluginRoute::AppUnavailable
        };
    }

    if auth_mode == Some(AuthMode::ApiKey) {
        return PluginRoute::McpPreferred;
    }

    PluginRoute::Default
}

fn is_dual_surface_plugin(plugin: &PluginCapabilitySummary) -> bool {
    !plugin.app_connector_ids.is_empty() && !plugin.mcp_server_names.is_empty()
}

fn plugin_has_available_connector(
    plugin: &PluginCapabilitySummary,
    available_connectors: &[AppInfo],
) -> bool {
    let plugin_connector_ids = plugin
        .app_connector_ids
        .iter()
        .map(|connector_id| connector_id.0.as_str())
        .collect::<HashSet<_>>();

    available_connectors.iter().any(|connector| {
        connector.is_accessible
            && connector.is_enabled
            && plugin_connector_ids.contains(connector.id.as_str())
    })
}

#[cfg(test)]
mod tests {
    use codex_plugin::AppConnectorId;

    use super::*;

    fn plugin(app_ids: &[&str], mcp_server_names: &[&str]) -> PluginCapabilitySummary {
        PluginCapabilitySummary {
            config_name: "sample@personal".to_string(),
            display_name: "Sample".to_string(),
            app_connector_ids: app_ids
                .iter()
                .map(|id| AppConnectorId((*id).to_string()))
                .collect(),
            mcp_server_names: mcp_server_names
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
            ..PluginCapabilitySummary::default()
        }
    }

    fn connector(id: &str, is_accessible: bool, is_enabled: bool) -> AppInfo {
        AppInfo {
            id: id.to_string(),
            name: id.to_string(),
            description: None,
            logo_url: None,
            logo_url_dark: None,
            distribution_channel: None,
            branding: None,
            app_metadata: None,
            labels: None,
            install_url: None,
            is_accessible,
            is_enabled,
            plugin_display_names: Vec::new(),
        }
    }

    struct RouteCase {
        name: &'static str,
        plugin: PluginCapabilitySummary,
        connectors: Vec<AppInfo>,
        auth_mode: Option<AuthMode>,
        expected_plugin_route: PluginRoute,
    }

    #[test]
    fn routes_plugins_by_auth_mode() {
        let cases = vec![
            RouteCase {
                name: "chatgpt dual-surface app available",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", true, true)],
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::AppPreferred,
            },
            RouteCase {
                name: "chatgpt dual-surface app missing",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: Vec::new(),
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::AppUnavailable,
            },
            RouteCase {
                name: "chatgpt dual-surface app inaccessible",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", false, true)],
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::AppUnavailable,
            },
            RouteCase {
                name: "chatgpt dual-surface app disabled",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", true, false)],
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::AppUnavailable,
            },
            RouteCase {
                name: "api-key dual-surface plugin",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", true, true)],
                auth_mode: Some(AuthMode::ApiKey),
                expected_plugin_route: PluginRoute::McpPreferred,
            },
            RouteCase {
                name: "unknown auth dual-surface plugin",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", true, true)],
                auth_mode: None,
                expected_plugin_route: PluginRoute::Default,
            },
            RouteCase {
                name: "agent identity dual-surface plugin",
                plugin: plugin(&["connector_sample"], &["sample-mcp"]),
                connectors: vec![connector("connector_sample", true, true)],
                auth_mode: Some(AuthMode::AgentIdentity),
                expected_plugin_route: PluginRoute::Default,
            },
            RouteCase {
                name: "chatgpt app-only plugin",
                plugin: plugin(&["connector_sample"], &[]),
                connectors: vec![connector("connector_sample", true, true)],
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::Default,
            },
            RouteCase {
                name: "chatgpt mcp-only plugin",
                plugin: plugin(&[], &["sample-mcp"]),
                connectors: Vec::new(),
                auth_mode: Some(AuthMode::Chatgpt),
                expected_plugin_route: PluginRoute::Default,
            },
        ];

        for case in cases {
            assert_eq!(
                route_for_plugin(&case.plugin, &case.connectors, case.auth_mode),
                case.expected_plugin_route,
                "{}",
                case.name
            );
        }
    }
}
