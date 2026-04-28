import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/fake_data.dart';
import '../data/disruption_library.dart';
import '../data/app_state.dart';
import '../widgets/common.dart';
import '../widgets/network_map.dart';
import '../services/api_service.dart';

class OpsDashboard extends StatefulWidget {
  const OpsDashboard({super.key});

  @override
  State<OpsDashboard> createState() => _OpsDashboardState();
}

class _OpsDashboardState extends State<OpsDashboard> {
  @override
  Widget build(BuildContext context) {
    // Listen to shared state — rebuild when disruption changes
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, _) {
        final state = AppState.instance;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(state),
              const SizedBox(height: 16),
              _buildKpiRow(state),
              const SizedBox(height: 16),
              SizedBox(
                height: 620,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: NetworkMap(
                        disruptedHubId: state.activeDisruption?.hubId.startsWith('HUB-') == true
                            ? state.activeDisruption!.hubId
                            : null,
                        showCascade: state.hasActiveDisruption,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          Expanded(flex: 6, child: _buildDisruptionPanel(state)),
                          const SizedBox(height: 12),
                          Expanded(flex: 4, child: _buildNewsPanel(state)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!state.whatIfMode && state.hasActiveDisruption) ...[
                const SizedBox(height: 16),
                _buildDisruptionBar(state),
              ],
              if (state.whatIfMode && state.stackedScenarios.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildWhatIfBar(state),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(AppState state) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('Operations', style: AppTheme.h1),
                  const SizedBox(width: 10),
                  _ModeChip(whatIf: state.whatIfMode),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                state.whatIfMode
                    ? 'What-if mode · stack scenarios to stress-test the network'
                    : 'Real-time view across 15 hubs · 200 shipments',
                style: AppTheme.bodyMuted,
              ),
            ],
          ),
        ),
        _ModeToggle(
          whatIf: state.whatIfMode,
          onChanged: (v) => state.setWhatIfMode(v),
        ),
      ],
    );
  }

  Widget _buildKpiRow(AppState state) {
    if (state.whatIfMode) {
      return _buildWhatIfKpiRow(state);
    }
    return Row(
      children: [
        Expanded(child: KpiCard(
          label: 'Active shipments',
          value: FakeData.activeShipments.toString(),
          icon: Icons.local_shipping_outlined,
        )),
        const SizedBox(width: 12),
        Expanded(child: KpiCard(
          label: 'At risk · cascade',
          value: state.atRisk.toString(),
          accentColor: state.atRisk > 0 ? AppTheme.risk : AppTheme.ink,
          delta: state.atRisk > 0
              ? (state.usedGnn ? '↑ GNN model' : '↑ detected in 3s')
              : '—',
          icon: Icons.warning_amber_outlined,
        )),
        const SizedBox(width: 12),
        Expanded(child: KpiCard(
          label: 'Rerouted today',
          value: state.reroutedCount.toString(),
          accentColor: AppTheme.ok,
          icon: Icons.alt_route_outlined,
        )),
        const SizedBox(width: 12),
        Expanded(child: KpiCard(
          label: 'Value preserved',
          value: state.savings,
          accentColor: AppTheme.accent,
          icon: Icons.savings_outlined,
        )),
      ],
    );
  }

  /// What-If KPI row: shows stress gauge + Without AI vs With AI comparison
  Widget _buildWhatIfKpiRow(AppState state) {
    final hasStack = state.stackedScenarios.isNotEmpty;
    return Column(
      children: [
        // Row 1: Stress gauge + counter
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _StressGauge(
                stress: state.networkStress,
                label: state.stressLabel,
                stackCount: state.stackedScenarios.length,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: KpiCard(
                label: 'Stacked scenarios',
                value: state.stackedScenarios.length.toString(),
                accentColor: state.stackedScenarios.isEmpty
                    ? AppTheme.inkMuted
                    : AppTheme.accent,
                delta: hasStack ? 'click to add · click again to remove' : 'click scenarios to stack',
                icon: Icons.layers_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Row 2: Without AI vs With AI side-by-side
        Row(
          children: [
            Expanded(
              child: KpiCard(
                label: 'Without ResilientNet',
                value: '${state.shipmentsDelayedWithoutAi}%',
                accentColor: AppTheme.risk,
                delta: hasStack ? 'shipments delayed · cascades unchecked' : 'stack scenarios to see impact',
                icon: Icons.trending_down,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: KpiCard(
                label: 'With ResilientNet',
                value: '${state.shipmentsDelayedWithAi}%',
                accentColor: AppTheme.ok,
                delta: hasStack
                    ? '↑ ${state.shipmentsSavedByAi}% saved · ${state.valueSavedByAi} preserved'
                    : 'AI absorbs cascades',
                icon: Icons.trending_up,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDisruptionPanel(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('DISRUPTION SIGNALS', style: TextStyle(
                  fontSize: 10, color: AppTheme.ink,
                  fontWeight: FontWeight.w700, letterSpacing: 1.4,
                )),
                const SizedBox(height: 4),
                Text(
                  '${DisruptionLibrary.all.length} scenarios · scroll to see more',
                  style: AppTheme.bodyMuted.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: AppTheme.border),
          Expanded(
            child: Scrollbar(
              thumbVisibility: true,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: DisruptionLibrary.all.length,
                itemBuilder: (context, i) {
                  final s = DisruptionLibrary.all[i];
                  final isActiveOrStacked = state.whatIfMode
                      ? state.stackedScenarios.any((x) => x.id == s.id)
                      : state.activeDisruption?.id == s.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _DisruptionTile(
                      scenario: s,
                      onTap: state.loading
                          ? null
                          : () => state.whatIfMode
                              ? state.stackOrUnstack(s)
                              : state.triggerDisruption(s),
                      isActive: isActiveOrStacked,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewsPanel(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Live news feed', style: AppTheme.h2),
                      const SizedBox(height: 2),
                      Text('Gemini · click any to trigger',
                          style: AppTheme.bodyMuted.copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.okSoft,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: const BoxDecoration(
                          color: AppTheme.ok, shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('LIVE', style: TextStyle(
                        fontSize: 10, color: AppTheme.ok,
                        fontWeight: FontWeight.w700, letterSpacing: 0.6,
                      )),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: AppTheme.border),
          Expanded(child: _LiveNewsFeed(state: state)),
        ],
      ),
    );
  }

  Widget _buildDisruptionBar(AppState state) {
    final scenario = state.activeDisruption!;
    final rerouted = state.rerouted;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: rerouted ? AppTheme.okSoft : AppTheme.riskSoft,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: rerouted ? AppTheme.okBorder : AppTheme.riskBorder,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          if (state.loading)
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            Icon(
              rerouted ? Icons.check_circle_outlined : Icons.warning_amber_rounded,
              size: 18,
              color: rerouted ? AppTheme.ok : AppTheme.risk,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      rerouted ? 'Cascade contained' : 'Cascade detected',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: rerouted ? AppTheme.ok : AppTheme.risk,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (state.backendOffline)
                      _StatusChip('OFFLINE · DEMO MODE',
                          AppTheme.warn, AppTheme.warnSoft, AppTheme.warnBorder)
                    else if (state.usedGnn)
                      _StatusChip('LIVE · ST-GCN · MAE 0.033',
                          AppTheme.accent, AppTheme.accentSoft, AppTheme.accent.withOpacity(0.3))
                    else if (state.algorithm != null)
                      _StatusChip('LIVE · ${state.confidence != null ? "${(state.confidence! * 100).toInt()}% conf" : "backend"}',
                          AppTheme.accent, AppTheme.accentSoft, AppTheme.accent.withOpacity(0.3)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  rerouted
                      ? '${scenario.opsLabel} · ${state.atRisk} shipments rerouted · ${state.savings} preserved'
                      : '${scenario.opsLabel} · ${state.atRisk} shipments affected · cascade depth ${state.usedGnn ? "1-hop" : "3-hop"}',
                  style: TextStyle(
                    fontSize: 12,
                    color: (rerouted ? AppTheme.ok : AppTheme.risk).withOpacity(0.9),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (!rerouted)
            PrimaryButton(
              label: state.loading ? 'Running...' : 'Run optimizer',
              icon: Icons.auto_fix_high,
              onTap: state.loading ? null : () => state.runOptimizer(),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: state.reset,
            color: AppTheme.inkMuted,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  /// What-If stress test bar — shown when user has stacked scenarios.
  /// Summarises what they've stacked and offers a clear-all button.
  Widget _buildWhatIfBar(AppState state) {
    final count = state.stackedScenarios.length;
    final summary = state.stackedScenarios
        .map((s) => s.shortLabel.split('—').first.trim())
        .join(' + ');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppTheme.accentSoft,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.accent.withOpacity(0.3), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 18, color: AppTheme.accentDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Stress test · $count scenario${count == 1 ? "" : "s"} stacked',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: AppTheme.accentDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Compound impact: $summary · network stress ${(state.networkStress * 100).toInt()}% · ${state.valueSavedByAi} preserved by ResilientNet',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.accentDark.withOpacity(0.9),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          SecondaryButton(
            label: 'Clear stack',
            icon: Icons.clear_all,
            onTap: state.clearStack,
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => state.setWhatIfMode(false),
            color: AppTheme.inkMuted,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// WHAT-IF STRESS GAUGE
// ============================================================

/// Visual gauge that grows as more scenarios stack. Color shifts from
/// green (stable) through amber (stressed) to red (breaking point).
class _StressGauge extends StatelessWidget {
  final double stress;    // 0-1
  final String label;     // STABLE | STRESSED | CRITICAL | BREAKING POINT
  final int stackCount;

  const _StressGauge({
    required this.stress,
    required this.label,
    required this.stackCount,
  });

  Color _stressColor() {
    if (stress < 0.25) return AppTheme.ok;
    if (stress < 0.50) return AppTheme.warn;
    if (stress < 0.75) return AppTheme.risk;
    return AppTheme.risk;
  }

  Color _stressSoft() {
    if (stress < 0.25) return AppTheme.okSoft;
    if (stress < 0.50) return AppTheme.warnSoft;
    return AppTheme.riskSoft;
  }

  @override
  Widget build(BuildContext context) {
    final color = _stressColor();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _stressSoft(),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: color.withOpacity(0.4), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.speed, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                'NETWORK STRESS',
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${(stress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 32,
                  color: color,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  stackCount == 0
                      ? 'add a scenario'
                      : stackCount == 1
                          ? '1 scenario active'
                          : '$stackCount scenarios active',
                  style: TextStyle(
                    fontSize: 11,
                    color: color.withOpacity(0.85),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Segmented stress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(
                  height: 6,
                  color: AppTheme.border,
                ),
                FractionallySizedBox(
                  widthFactor: stress.clamp(0.0, 1.0),
                  child: Container(
                    height: 6,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SUB-WIDGETS
// ============================================================

class _StatusChip extends StatelessWidget {
  final String label;
  final Color fg, bg, border;
  const _StatusChip(this.label, this.fg, this.bg, this.border);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: border, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _DisruptionTile extends StatelessWidget {
  final DisruptionScenario scenario;
  final VoidCallback? onTap;
  final bool isActive;

  const _DisruptionTile({
    required this.scenario,
    required this.onTap,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final isStrike = scenario.type == DisruptionType.strike;
    final isLowSev = scenario.severity < 0.5;
    final bg = isLowSev
        ? AppTheme.warnSoft
        : isStrike ? AppTheme.warnSoft : AppTheme.riskSoft;
    final fg = isLowSev
        ? AppTheme.warn
        : isStrike ? AppTheme.warn : AppTheme.risk;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: isActive
                ? Border.all(color: fg, width: 1.2)
                : null,
          ),
          child: Row(
            children: [
              Icon(_iconFor(scenario.type), size: 15, color: fg),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      scenario.shortLabel,
                      style: TextStyle(
                        color: fg, fontSize: 12, fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      scenario.tagline + (scenario.engine == BackendEngine.gnn ? ' · GNN' : ''),
                      style: TextStyle(
                        color: fg.withOpacity(0.75), fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isActive)
                Icon(Icons.check_circle, size: 14, color: fg)
              else
                Icon(Icons.play_arrow_rounded, size: 14, color: fg.withOpacity(0.7)),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(DisruptionType t) {
    switch (t) {
      case DisruptionType.storm: return Icons.cyclone;
      case DisruptionType.strike: return Icons.campaign_outlined;
      case DisruptionType.closure: return Icons.block;
      case DisruptionType.accident: return Icons.warning_amber;
      case DisruptionType.fire: return Icons.local_fire_department_outlined;
      case DisruptionType.fuel: return Icons.local_gas_station_outlined;
      case DisruptionType.customs: return Icons.gavel;
      case DisruptionType.conflict: return Icons.security;
      case DisruptionType.mechanical: return Icons.build_outlined;
      case DisruptionType.flood: return Icons.water;
    }
  }
}

// ── Live News Feed — polls /realtime/events every 30s ──────────────────────

class _LiveNewsFeed extends StatefulWidget {
  final AppState state;
  const _LiveNewsFeed({required this.state});

  @override
  State<_LiveNewsFeed> createState() => _LiveNewsFeedState();
}

class _LiveNewsFeedState extends State<_LiveNewsFeed> {
  List<RealtimeEvent> _liveEvents = [];
  bool _loading = true;
  bool _backendReachable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() { _loading = _liveEvents.isEmpty; _error = null; });
    try {
      final events = await ApiService.fetchRealtimeEvents(limit: 30);
      if (mounted) setState(() { _liveEvents = events; _loading = false; _backendReachable = true; });
      // Auto-refresh every 30 seconds
      await Future.delayed(const Duration(seconds: 30));
      if (mounted) _fetch();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    // If backend has no live events yet, fall back to static library
    final useStatic = !_backendReachable && !_loading;

    if (_loading && _liveEvents.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 10),
            Text('Fetching live headlines...', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }

    if (useStatic) {
      // Fallback to hardcoded library with a banner
      return Column(
        children: [
          if (!_backendReachable) Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Colors.orange.withOpacity(0.1),
            child: Row(
              children: [
                const Icon(Icons.wifi_off, size: 13, color: Colors.orange),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Backend offline — showing demo scenarios',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
                GestureDetector(
                  onTap: _fetch,
                  child: const Text('Retry',
                      style: TextStyle(fontSize: 11, color: Colors.blue)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              thumbVisibility: true,
              child: ListView.separated(
                padding: EdgeInsets.zero,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: DisruptionLibrary.allHeadlines.length,
                separatorBuilder: (_, __) =>
                    Container(height: 0.5, color: AppTheme.border),
                itemBuilder: (ctx, i) {
                  final headline = DisruptionLibrary.allHeadlines[i];
                  final scenario = DisruptionLibrary.all[i];
                  final isActive = widget.state.whatIfMode
                      ? widget.state.stackedScenarios.any((x) => x.id == scenario.id)
                      : widget.state.activeDisruption?.id == scenario.id;
                  return _NewsHeadlineItem(
                    headline: headline,
                    location: scenario.location,
                    isActive: isActive,
                    onTap: widget.state.loading
                        ? null
                        : () => widget.state.whatIfMode
                            ? widget.state.stackOrUnstack(scenario)
                            : widget.state.triggerDisruption(scenario),
                  );
                },
              ),
            ),
          ),
        ],
      );
    }

    // Live events from backend
    return Column(
      children: [
        // "Refresh now" bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          color: AppTheme.okSoft,
          child: Row(
            children: [
              const Icon(Icons.fiber_manual_record, size: 8, color: AppTheme.ok),
              const SizedBox(width: 6),
              Text(
                '${_liveEvents.length} live headlines from NewsAPI',
                style: const TextStyle(fontSize: 11, color: AppTheme.ok, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () async {
                  await ApiService.pollNow();
                  await Future.delayed(const Duration(seconds: 3));
                  _fetch();
                },
                child: const Text('↻ Refresh',
                    style: TextStyle(fontSize: 11, color: Colors.blue)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: ListView.separated(
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _liveEvents.length,
              separatorBuilder: (_, __) =>
                  Container(height: 0.5, color: AppTheme.border),
              itemBuilder: (ctx, i) {
                final event = _liveEvents[i];
                return _LiveHeadlineTile(event: event, state: widget.state);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _LiveHeadlineTile extends StatelessWidget {
  final RealtimeEvent event;
  final AppState state;
  const _LiveHeadlineTile({required this.event, required this.state});

  @override
  Widget build(BuildContext context) {
    final severityColor = event.severity >= 0.8
        ? AppTheme.risk
        : event.severity >= 0.5
            ? Colors.orange
            : Colors.amber;

    return InkWell(
      onTap: state.loading
          ? null
          : () async {
              // Try to match the headline to a curated scenario by keywords.
              // This works for ~60% of NewsAPI headlines because the library
              // covers cyclones, strikes, port closures, accidents, fires, etc.
              final matched = DisruptionLibrary.byHeadlineMatch(event.headline);

              if (matched != null) {
                // Found a curated match — use it (gives us per-persona detail)
                state.triggerDisruption(matched);
              } else {
                // No match — synthesize a scenario from the live event itself
                // so the user still sees something happen (location-aware)
                final synth = _synthesizeFromLiveEvent(event);
                if (synth != null) {
                  state.triggerDisruption(synth);
                } else {
                  // Last resort — pick the scenario closest by type/location
                  final fallback = _bestGuessScenario(event);
                  if (fallback != null) state.triggerDisruption(fallback);
                }
              }
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.typeIcon, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.headline,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        event.location ?? event.source,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500],
                            fontFamily: 'monospace'),
                      ),
                      if (event.shipmentsAtRisk > 0) ...[
                        const SizedBox(width: 8),
                        Text('· ${event.shipmentsAtRisk} at risk',
                            style: TextStyle(fontSize: 11, color: severityColor)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: severityColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: severityColor.withOpacity(0.4)),
                  ),
                  child: Text(
                    event.severityLabel,
                    style: TextStyle(fontSize: 9, color: severityColor,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                if (event.isRealtime) ...[
                  const SizedBox(height: 4),
                  const Text('LIVE',
                      style: TextStyle(fontSize: 9, color: Colors.blue,
                          fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LIVE EVENT → SCENARIO MAPPING HELPERS
// ============================================================

/// Build a synthetic DisruptionScenario from a live NewsAPI event.
/// Uses Gemini's parsed location + type to pick a sensible hub and engine.
DisruptionScenario? _synthesizeFromLiveEvent(RealtimeEvent event) {
  // Map the parsed type to an enum value
  final typeStr = event.type.toLowerCase();
  DisruptionType type;
  if (typeStr.contains('storm') || typeStr.contains('cyclone')) {
    type = DisruptionType.storm;
  } else if (typeStr.contains('strike')) {
    type = DisruptionType.strike;
  } else if (typeStr.contains('accident') || typeStr.contains('crash')) {
    type = DisruptionType.accident;
  } else if (typeStr.contains('flood')) {
    type = DisruptionType.flood;
  } else if (typeStr.contains('fire')) {
    type = DisruptionType.fire;
  } else if (typeStr.contains('fuel')) {
    type = DisruptionType.fuel;
  } else if (typeStr.contains('customs')) {
    type = DisruptionType.customs;
  } else if (typeStr.contains('conflict') || typeStr.contains('attack')) {
    type = DisruptionType.conflict;
  } else if (typeStr.contains('mechanical') || typeStr.contains('crane')) {
    type = DisruptionType.mechanical;
  } else {
    type = DisruptionType.closure;  // generic fallback
  }

  // Pick engine + hub based on Gemini's location guess
  final location = (event.location ?? '').toLowerCase();
  BackendEngine engine;
  String hubId;
  String displayLocation;

  // South India hubs use the GNN
  if (location.contains('kochi') || location.contains('cochin')) {
    engine = BackendEngine.gnn; hubId = 'Kochi Port'; displayLocation = 'Kochi Port';
  } else if (location.contains('chennai')) {
    engine = BackendEngine.gnn; hubId = 'Chennai Port'; displayLocation = 'Chennai Port';
  } else if (location.contains('bengaluru') || location.contains('bangalore')) {
    engine = BackendEngine.gnn; hubId = 'Bengaluru Warehouse'; displayLocation = 'Bengaluru DC';
  } else if (location.contains('hyderabad')) {
    engine = BackendEngine.gnn; hubId = 'Hyderabad Warehouse'; displayLocation = 'Hyderabad';
  } else if (location.contains('vizag') || location.contains('vishakhapatnam')) {
    engine = BackendEngine.gnn; hubId = 'Vizag Port'; displayLocation = 'Vizag Port';
  }
  // International hubs use the hand-crafted engine
  else if (location.contains('mumbai') || location.contains('jnpt') || location.contains('nhava')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-00'; displayLocation = 'Mumbai Port';
  } else if (location.contains('delhi')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-04'; displayLocation = 'Delhi ICD';
  } else if (location.contains('kolkata')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-13'; displayLocation = 'Kolkata Port';
  } else if (location.contains('jebel ali') || location.contains('red sea') || location.contains('suez')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-10'; displayLocation = 'Jebel Ali / Red Sea';
  } else if (location.contains('singapore')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-09'; displayLocation = 'Singapore';
  } else if (location.contains('rotterdam')) {
    engine = BackendEngine.handcrafted; hubId = 'HUB-11'; displayLocation = 'Rotterdam';
  } else {
    // Couldn't resolve location — return null so caller falls back
    return null;
  }

  // Generic per-persona content based on the headline
  final shortHeadline = event.headline.length > 60
      ? '${event.headline.substring(0, 60)}…'
      : event.headline;

  return DisruptionScenario(
    id: 'live_${event.id.isNotEmpty ? event.id : DateTime.now().millisecondsSinceEpoch}',
    shortLabel: 'LIVE: $displayLocation',
    tagline: 'From NewsAPI',
    type: type,
    engine: engine,
    hubId: hubId,
    severity: event.severity > 0 ? event.severity : 0.7,
    newsHeadline: event.headline,
    location: displayLocation,
    driverImpact: DriverImpact(
      alertHeadline: 'Disruption near $displayLocation',
      alertDetail: shortHeadline,
      originalRouteLabel: 'Through $displayLocation',
      originalRouteEta: 'as scheduled',
      originalRouteRiskPercent: ((event.severity > 0 ? event.severity : 0.7) * 100).round(),
      originalRouteIssue: 'live disruption detected',
      newRouteLabel: 'Reroute via alternate hub',
      newRouteEta: '+1-3 hours',
      newRouteRiskPercent: 22,
      newRouteIssue: 'unaffected corridor',
      shipmentContext: 'Active shipment through $displayLocation',
    ),
    customerImpact: CustomerImpact(
      notificationHeadline: 'Live disruption · we are protecting your delivery',
      notificationBody: shortHeadline,
      cargoDescription: 'Your shipment',
      customerName: 'Customer',
      arrivalDisplay: 'Slight delay expected',
      trustFooter: 'Detected via NewsAPI · severity ${(event.severity * 100).toInt()}%',
    ),
  );
}

/// Last-resort fallback — match by location keyword in the headline,
/// not by structured fields. Returns the closest curated scenario.
DisruptionScenario? _bestGuessScenario(RealtimeEvent event) {
  final headline = event.headline.toLowerCase();
  // Look for any city name in the headline
  for (final s in DisruptionLibrary.all) {
    final loc = s.location.toLowerCase();
    final firstWord = loc.split(' ').first.split('/').first;
    if (firstWord.length >= 4 && headline.contains(firstWord)) {
      return s;
    }
  }
  // Type-based fallback
  final type = event.type.toLowerCase();
  for (final s in DisruptionLibrary.all) {
    if (s.type.name.toLowerCase().contains(type) ||
        type.contains(s.type.name.toLowerCase())) {
      return s;
    }
  }
  return null;
}

class _NewsHeadlineItem extends StatefulWidget {
  final String headline;
  final String location;
  final bool isActive;
  final VoidCallback? onTap;

  const _NewsHeadlineItem({
    required this.headline,
    required this.location,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_NewsHeadlineItem> createState() => _NewsHeadlineItemState();
}

class _NewsHeadlineItemState extends State<_NewsHeadlineItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: widget.isActive
              ? AppTheme.accentSoft
              : (_hover ? AppTheme.surfaceSubtle : Colors.transparent),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4, right: 10),
                width: 5, height: 5,
                decoration: BoxDecoration(
                  color: widget.isActive ? AppTheme.accent : AppTheme.inkMuted,
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.headline,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppTheme.ink,
                        fontWeight: widget.isActive || _hover
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.location,
                      style: AppTheme.monoSmall.copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (_hover || widget.isActive) ...[
                const SizedBox(width: 6),
                Icon(
                  widget.isActive ? Icons.check_circle : Icons.arrow_forward,
                  size: 12,
                  color: AppTheme.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// MODE WIDGETS (unchanged from prior version)
// ============================================================

class _ModeChip extends StatelessWidget {
  final bool whatIf;
  const _ModeChip({required this.whatIf});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: whatIf ? AppTheme.infoSoft : AppTheme.okSoft,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: whatIf ? AppTheme.infoBorder : AppTheme.okBorder, width: 0.5,
        ),
      ),
      child: Text(
        whatIf ? 'SIMULATION' : 'LIVE',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: whatIf ? AppTheme.info : AppTheme.ok,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final bool whatIf;
  final ValueChanged<bool> onChanged;

  const _ModeToggle({required this.whatIf, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.border, width: 0.5),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggleBtn('Live', !whatIf, () => onChanged(false)),
          _toggleBtn('What-if', whatIf, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _toggleBtn(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppTheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? AppTheme.ink : AppTheme.inkMuted,
          ),
        ),
      ),
    );
  }
}