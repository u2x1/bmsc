import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';

import '../database_manager.dart';
import '../model/play_stat.dart';
import '../screen/local_history_screen.dart';
import '../service/audio_service.dart';
import '../util/recent_picks.dart';
import 'section_header.dart';

/// 主页「最近在听」：本地播放统计（play_stat JOIN meta）经加权随机推荐
/// （见 recent_picks.dart）取前 27，按 3×3 九宫格分页，左右滑动翻页，
/// 页数 >1 时下方显示圆点指示。点击入队播放并定位到上次听到的
/// 分 P（play_stat.last_cid，无记录时从 P1 开始）。
/// 标题行整体可点击，打开本地历史记录列表。历史为空时整段隐藏。
class RecentListeningGrid extends StatefulWidget {
  const RecentListeningGrid({super.key});

  @override
  State<RecentListeningGrid> createState() => _RecentListeningGridState();
}

class _RecentListeningGridState extends State<RecentListeningGrid> {
  static const _pageSize = 9;
  static const _spacing = 10.0;

  List<PlayStat> _items = [];
  final _pageController = PageController();
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 候选池取最近 60 条，加权随机抽 27（3 页），避免每次都是同样的九首
    final pool = await DatabaseManager.getPlayHistory(limit: 60);
    if (!mounted) return;
    setState(() => _items = pickRecentListening(pool, take: _pageSize * 3));
  }

  static String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  /// 返回 sliver（供主页 CustomScrollView 使用）：header 吸顶，
  /// 板块可见时自绘底部分隔条，与下一分区间界限明确。
  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final pages = (_items.length + _pageSize - 1) ~/ _pageSize;
    return SliverStickyHeader(
      header: SectionHeader(
        icon: Icons.history,
        title: '最近在听',
        trailing: Text(
          '全部历史 ›',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<Widget>(
              builder: (_) => const LocalHistoryScreen()),
        ),
      ),
      sliver: SliverToBoxAdapter(
        child: Column(
          children: [
            // 外层 margin 减去 _spacing，每页内部再加回 _spacing 水平
            // 内边距（见 _buildGridPage）：静止时格子仍对齐分区的 24px
            // 间距，横向翻页时相邻两页之间露出 2*_spacing 的间隙，
            // 避免两页的格子连在一起
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24.0 - _spacing),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 封面是 B 站 16:9 横图（非方形）：按实际可用宽度计算格宽，
                  // 格高 = 封面高 + 间距 + 两行标题，避免 GridView 溢出。
                  // 注意每页内部还有 _spacing 水平内边距（翻页间隙），
                  // 故格宽需减去 4 倍 _spacing
                  final cellWidth = (constraints.maxWidth - _spacing * 4) / 3;
                  // 两行标题预算随系统字体缩放（固定值在大字体下溢出）
                  final textScale = MediaQuery.textScalerOf(context).scale(1.0);
                  final cellHeight = cellWidth * 9 / 16 + 4 + 32 * textScale;
                  // 高度按实际行数：不足一整页（9 个）时不预留满 3 行，
                  // 避免网格下方出现大段空白；多页时首页总是满 3 行
                  final rows = _items.length >= _pageSize
                      ? 3
                      : (_items.length + 2) ~/ 3;
                  final pageHeight =
                      cellHeight * rows + _spacing * (rows - 1);
                  return SizedBox(
                    height: pageHeight + (pages > 1 ? 16 : 0),
                    child: Column(
                      children: [
                        Expanded(
                          child: PageView.builder(
                            controller: _pageController,
                            itemCount: pages,
                            onPageChanged: (i) => setState(() => _page = i),
                            itemBuilder: (context, pageIndex) => _buildGridPage(
                                pageIndex, cellWidth / cellHeight),
                          ),
                        ),
                        if (pages > 1) _buildPageDots(pages),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            const SectionDivider(),
          ],
        ),
      ),
    );
  }

  Widget _buildGridPage(int pageIndex, double childAspectRatio) {
    final start = pageIndex * _pageSize;
    final end =
        (start + _pageSize) > _items.length ? _items.length : start + _pageSize;
    // 页内水平内边距：横向翻页时与相邻页之间露出间隙；
    // 与外层 margin 抵消后静止时仍对齐分区 24px 间距
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _spacing),
      child: GridView.builder(
        // 在 PageView 页内高度有界，直接铺满一页，自身不滚动
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: _spacing,
          crossAxisSpacing: _spacing,
          childAspectRatio: childAspectRatio,
        ),
        itemCount: end - start,
        itemBuilder: (context, index) => _buildCell(_items[start + index]),
      ),
    );
  }

  Widget _buildPageDots(int pages) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < pages; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == _page
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCell(PlayStat stat) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      // B 站曲目：定位到上次听到的分 P（play_stat.last_cid）续播，
      // 旧数据无记录时从 P1 开始；本地音乐曲目直接单曲续播
      onTap: () => AudioService.instance.then((x) {
        if (stat.isLocal) {
          final localId = int.tryParse(stat.bvid.substring(6));
          if (localId != null) return x.playLocalTrackById(localId);
        }
        return x.playByBvid(stat.bvid, preferCid: stat.lastCid);
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCover(stat),
                  // 时长为 0 的本地文件（元数据缺失）不显示角标
                  if (stat.duration != null && stat.duration! > 0)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.54),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatDuration(stat.duration!),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 9),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            stat.title ?? stat.bvid,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(PlayStat stat) {
    final artUri = stat.artUri;
    final placeholder = Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.primary,
        size: 24,
      ),
    );
    if (artUri == null || artUri.isEmpty) return placeholder;
    // 本地音乐封面为本地文件路径
    if (stat.isLocal) {
      return Image.file(
        File(artUri),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    }
    // 居中裁剪为 16:9（B 站封面为横图）；320×180 适配 3x 视网膜
    return CachedNetworkImage(
      imageUrl: '$artUri@320w_180h_1c',
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );
  }
}
