import 'package:bmsc/service/bilibili_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../model/comment.dart';
import '../theme.dart';
// import '../util/logger.dart';

// final _logger = LoggerUtils.getLogger('CommentScreen');

class CommentScreen extends StatefulWidget {
  final String? aid;
  final int? oid;
  final int? root;
  final int? total;

  const CommentScreen({super.key, this.aid, this.oid, this.root, this.total});

  @override
  State<CommentScreen> createState() => _CommentScreenState();
}

class _CommentScreenState extends State<CommentScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<ItemInfo> _comments = [];
  int? _nextPage;
  String? _nextOffset;
  bool _isLoading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadComments();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _hasMore) {
      _loadComments();
    }
  }

  Future<void> _loadComments() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    CommentData? commentData;
    final bs = await BilibiliService.instance;
    if (widget.aid != null) {
      commentData = await bs.getComment(widget.aid!, _nextOffset);
    } else if (widget.oid != null && widget.root != null) {
      commentData = await bs.getCommentsOfComment(
          widget.oid!, widget.root!, _nextPage ?? 1);
    }

    setState(() {
      if (commentData?.replies != null) {
        _comments.addAll(commentData!.replies!);
        _nextPage = commentData.cursor?.next;
        _nextOffset = commentData.cursor?.nextOffset;
        _nextOffset = _nextOffset == null
            ? null
            : '{"offset":"${_nextOffset!.replaceAll('"', '\\"')}"}';
        if (widget.aid != null) {
          _hasMore = !commentData.cursor!.isEnd;
        } else {
          _hasMore = _comments.length < (widget.total ?? 0);
        }
      } else {
        _hasMore = false;
      }
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('评论')),
      body: ListView.separated(
        controller: _scrollController,
        itemCount: _comments.length + (_isLoading ? 1 : 0),
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == _comments.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            );
          }

          final comment = _comments[index];
          return GestureDetector(
            onTap: () {
              if (comment.replies != null && comment.replies!.isNotEmpty) {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => CommentScreen(
                            oid: comment.oid,
                            root: comment.rpid,
                            total: comment.count)));
              }
            },
            onLongPress: () {
              if (comment.content?.message != null) {
                Clipboard.setData(
                    ClipboardData(text: comment.content!.message));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制内容到剪贴板'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        comment.member.uname,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        DateTime.fromMillisecondsSinceEpoch(
                                comment.ctime * 1000)
                            .toString()
                            .substring(0, 19),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${comment.like}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.thumb_up, size: 14, color: Colors.grey),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    comment.content?.message ?? '',
                    style: TextStyle(
                      fontSize:
                          ThemeProvider.instance.commentFontSize.toDouble(),
                    ),
                  ),
                  if (comment.count > 0)
                    Text('${comment.count} 条回复',
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
