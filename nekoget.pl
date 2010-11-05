#! /usr/bin/perl -W

use warnings;
use strict;

use URI;
use URI::file;
use LWP::UserAgent;
use Getopt::Long;
use File::Copy;
use threads;

################################################################################
# 色々
################################################################################

{
	package Ng;

	my $timeout = 5000;
	my $agent = 'NekoGet ver 0.893';
	my $debug = 0;

	sub timeout { $timeout = $_[0] if ($_[0]); }
	sub agent { $agent = $_[0] if ($_[0]); }
	sub debug { $debug = $_[0] if ($_[0]); }
	
	BEGIN {
		my $p = $0;
		$p =~ s/\.[^\.]+?$//;
		$p .= '.log';
		unlink $p;
		open DEBUGLOG, ">$p";
	}

	END {
		close DEBUGLOG;
	}
	
	# デバッグ用の出力にゃん
	sub dbg {
		return unless ($debug);
		my ($name, %rest) = @_;
		return unless ($name);
		print DEBUGLOG "[$name]\n";
		while (my($k, $v) = each %rest){
			next unless ($k);
			print DEBUGLOG "\t$k: ";
			print DEBUGLOG "$v" if ($v);
			print DEBUGLOG "\n";
		}
	}

	# げふ
	sub def ($$) {
		my ($value, $def) = @_;
		$def unless ($value);
	}

	# 指定のディレクトリを作るよ。ディレクトリの最後はスラじゃないとだめなのだ。
	sub make_dir ($) {
		my ($path) = @_;
		$path =~ s/[\\\/][^\\\/]+?$//;
		$path =~ s/\.$//; 
		Ng::dbg('Ng::make_dir', 'so', shift @_, 'de', $path);
		`mkdir -p "$path"`;
		return -e $path;
	}

	# httpで毒麺塗をゲット！	*第二引数指定でそこに値が格納される仕様
	#	info 7
	#		url
	#		filename
	#		referer
	#		auth
	#		timeout
	#		agent
	sub http_get ($;$) {

		my ($info, $content) = @_;
		Ng::dbg('Ng::http_get', %$info);

		my $req = HTTP::Request->new('GET' => $info->{'url'});
		my $ua = LWP::UserAgent->new;
		$req->referer($info->{'referer'});
		$req->authorization_basic($info->{'auth'}) if ($info->{'auth'});
		$ua->agent($info->{'agent'}) if ($info->{'agent'});
		$ua->timeout(Ng::def $info->{'timeout'}, $timeout);

		my $res;
		if ($content) {
			$res = $ua->request($req);
			$$content = $res->content;
		} else {
			$res = $ua->request($req, $info->{'filename'});
		}
		$info->{'urlobj'}->{'response'} = $res;

		return $res->is_success ? "success" : 0;
		
	}

	# ファイルからWArcのリストを抽出
	sub extract_arc_url {
		my ($content) = @_;
		my @urls;
		for ($content) {
			push @urls, $_ for (m[(http\://web\.archive\.org/web/\d+/http\://.+?)\"]g);
		}
		Ng::rm_amp(\$_) for (@urls);
		Ng::dbg('Ng::extract_arc_url','content', $content, 'urls', join("\n\t\t", @urls));
		return reverse @urls;
	}

	# 一時ファイル名を取得
	my $tmpfncount = 0;
	sub temp_filename : locked {
		my $pre = $ENV{'HOME'} . 'nekoget.tmp.';
		$tmpfncount++ while (-e ($pre . $tmpfncount));
		return $pre . $tmpfncount;
	}


	# ありえるファイル名にして返す
	sub reg_filename {
		my ($filename) = @_;
		$filename =~ s/([\:\;\*\?\"\<\>\|])/'%' . unpack('H2', $1)/eg;
		$filename =~ s/(^|[^\.])\.[\/\\]//g;
		Ng::dbg('Ng::reg_filename', 'so', shift @_, 'de', $filename);
		return $filename;
	}

	# / を除く
	sub rm_slash {
		my ($filename) = @_;
		$filename =~ s/([\\\/])/'%' . unpack('H2', $1)/eg;
		Ng::dbg('Ng::rm_slash', 'so', shift @_, 'de', $filename);
		return $filename;
	}
	
	# 実体参照を変換 
	sub rm_amp ($) {
		my ($url) = @_;
		$$url =~ s/\&amp;?/\&/g;
		$$url =~ s/\&lt;?/\</g;
		$$url =~ s/\&gt;?/\>/g;
		$$url =~ s/\&nbsp;?/ /g;
		$$url =~ s/\&quot;?/\"/g;
		return $$url;
	}

	# 1 は 2 上のURLか？
	sub is_child {
		my ($url, $base) = @_;
		my $chk = $url->rel($base);
		return $chk !~ m/^(http:\/\/|\.\.\/)/;
	}

	# WArcのエラーファイルか判定
	sub is_wa_error {
		my ($filename) = @_;
		open my $FILE, "$filename" or return 0;
		while (<$FILE>) {
			return 1 if (m[collections/web/styles/styles\.css]i);
			return 0 if ($. > 10);
		}
		close $FILE;
		return 0;
	}

	# URLショートカット
	sub make_url_link {
		my ($url, $filename) = @_;
		Ng::make_dir($filename);
		open my $FILE, ">$filename" or die "cannot open $filename";
		print $FILE "[InternetShortcut]\x0D\x0A";
		print $FILE "URL=$url\x0D\x0A";
		close $FILE;
	}
	
}


################################################################################
# URLクラス
################################################################################
{
	package NgUrl;

	# owner
	# 	NgItemオブジェクト
	# url
	# 	URL
	# ref_url
	# 	参照元

	sub new($$$) {
		my ($class, $owner, $url, $ref_url) = @_;
		my $obj = {'owner' => $owner, 'url' => $url, 'ref_url' => $ref_url, 'result' => 0};
		$obj->{'response'} = 0;
		bless $obj, $class;
		return $obj;
	}

	# 同じURLかなぁ？ オーナが違えば違う物。
	sub eq {
		my ($a, $b) = @_;
		return (($a->{'url'} eq $b->{'url'}) and ($a->{'owner'} eq $b->{'owner'}));
	}

	# 相対ファイル名
	sub filename_rel {
		my ($obj) = @_;
		my $src = $obj->{'url'}->rel($obj->{'owner'}->{'start_url'});
		my ($path, $arg) = $src =~ m/([^\?].+)\?(.+$)/;
		unless ($path) { 
			$path = $src;
			$path .= 'index.html' if (not $path or $path =~ m/[\\\/]$/);
		}
		$arg = Ng::rm_slash($arg) if ($arg);
		$path .= $arg if ($arg);
		$path = Ng::reg_filename($path);
		return $path;
	}

	# 保存ファイル名
	sub filename {
		my ($obj) = @_;
		my $ret = $obj->{'owner'}->{'store_dir'};
		$ret =~ s/\~/$ENV{'HOME'}/; 
		$ret =~ s/[\/\\]{2,}/\//g; 
		return $ret . $obj->filename_rel;
	}

	# 相対リンクに書き換える
	sub convert_rel {
		my ($obj, $nc) = @_;
		Ng::dbg('NgUrl::convert_rel', %$obj);
		sub _reg_url {
			my ($obj, $url, $nc) = @_;
			return $url if ($nc);
			return $url if ($url !~ m/^http:/ and $url =~ m/^[^:].+:/);  
			my $aurl = URI->new_abs($url, $obj->{'url'});
			my $eurl = $obj->{'owner'}->{'queue'}->find_url($aurl);
			$obj->push_urls($aurl);
			return $url unless ($eurl);
			my $efn = URI::file->new($eurl->filename);
			my $bfn = URI::file->new($obj->filename);
			(my $res = $efn->rel($bfn)) =~ s[^file://][];
			return $res;
		}
		my $sfn = $obj->filename;
		my $tfn = Ng::temp_filename;
    File::Copy::move($sfn, $tfn) unless ($nc);
		open my $IN, "$tfn";
		open my $OUT, ">$sfn" unless ($nc);
		while (my $line = <$IN>) {
			if ($line =~ m/var sWayBackCGI/) { 1 while (($line = <$IN>) !~ /\/\/--\>/); }
			$line =~ s[http://web.archive.org/web/\d+?/][]ig;
			$line =~ s[<base.+>][]ig;
			$line =~ s/(http:\/\/.+?)([^\w\-\/\.\?\~\'])/_reg_url($obj, $1, $nc) . $2/gei; 
			$line =~ s/href *?\=(["]?)([^#]+?)([ #">])/"href=$1" . _reg_url($obj, $2, $nc) . "$3"/ige;
			$line =~ s/src *?\=(["]?)([^#]+?)([ #">])/"src=$1" . _reg_url($obj, $2, $nc) . "$3"/ige;
			print $OUT $line unless ($nc);
		}
		close $IN;
		close $OUT unless ($nc);
		unlink $tfn unless ($nc);
	}

	# http_get用のinfo
	sub get_info {
		my ($obj) = @_;
		my $ow = $obj->{'owner'};
		my $info = { 
			'url' => $obj->{'url'}, 
			'filename' => $obj->filename, 
			'referer' => $obj->{'ref_url'},
			'agent' => $ow->{'agent'},
			'auth' => $ow->{'auth'},
			'timeout' => $ow->{'timeout'},
			'urlobj'=> $obj
		};
		return $info;
	}

	# きみはHTMLかにゃ？
	sub isHtml {
		my ($obj, $url) = @_;
		return 1 if ($url =~ m/((\.(s?html?|txt|xml|xhtml?))|\/)($|\?)/i);
		return 1 if ($obj->{'response'} and $obj->{'response'}->content_type =~ /text|html/i);		
	}

	# 正規の頁から取得
	sub get_std {
		my ($obj) = @_;
		my $info = $obj->get_info;
		Ng::dbg('NgUrl::get_std', %$info);
		return Ng::http_get $info;
	}

	# WArcから取得
	sub get_arc {
		my ($obj) = @_;
		my $info = $obj->get_info;
		$info->{'url'} = 'http://web.archive.org/web/*/' . $obj->{'url'};
		delete $info->{'auth'};
		Ng::dbg('NgUrl::get_arc', %$info);
		my $content;
		return 0 unless (Ng::http_get $info, \$content);
		my @arcUrls = Ng::extract_arc_url $content;
		my $from = $obj->{'owner'}->{'wafrom'};
		my $to = $obj->{'owner'}->{'wato'};
		for (@arcUrls) {
			$info->{'url'} = $_;
			my ($date) = m/.+?([0-9]{8})/;
			next if ($from and $date < $from) or ($to and $date > $to);
			if (Ng::http_get $info) {
				return 'success-arc' unless Ng::is_wa_error $info->{'filename'};
			}
		}
		return 0;
	}

	# ファイルからURLを探しプッシュしちゃうぞ！
	sub push_urls {
		my ($obj, @urls) = @_;
		for (@urls) {
			my $newUrl = URI->new_abs(Ng::rm_amp(\$_), $obj->{'url'});
			next unless ($obj->{'owner'}->accept($newUrl));
			$obj->{'owner'}->{'queue'}->push(NgUrl->new($obj->{'owner'}, $newUrl, $obj->{'url'}));
		}
	}
	
	# URLを明示的にしていするとそちらをGET
	sub get {
		my ($obj, $url) = @_;
		Ng::dbg('NgUrl::get', %$obj);
		$url = $obj->{'url'} unless ($url);
		my $res;
		$res = 'exists' if (-e $obj->filename);
		return $obj->{'result'} = 0 unless ($res or Ng::make_dir($obj->filename));
		$res = $obj->get_std unless ($obj->{'owner'}->{'retry'} and $res or $obj->{'owner'}->{'waonly'});
		$res = $obj->get_arc unless ($res or $obj->{'owner'}->{'nowa'});
		$obj->convert_rel if ($obj->isHtml($url) and $res and ($res ne 'exists' or $obj->{'owner'}->{'retry'}));
		$obj->{'result'} = $res;
		return $res;
	}


}

################################################################################
# 取得情報クラス
################################################################################
{
	package NgItem;

	# queue
	# 	キューオブジェクト
	# start_url
	# 	初期URL
	# store_dir
	# 	格納ディレクトリ

	sub new {
		my ($class, $obj) = @_;
		return 0 unless ($obj->{'start_url'} and $obj->{'store_dir'} and $obj->{'queue'});
		bless $obj, $class;
		$obj->{'queue'}->push($obj->first);
		Ng::make_url_link($obj->{'start_url'}, $obj->{'store_dir'} . '#link#.url');
		return $obj;
	}

	# 許可URL
	sub accept {
		my ($obj, $url) = @_;
		my $acceptRe = $obj->{'accept'};
		return m/$acceptRe/i if ($acceptRe);
		my $res = Ng::is_child($url->abs($obj->{'start_url'}), $obj->{'start_url'});
		Ng::dbg('NgUrl::accept', 'res', $res, 'url', $url, 'start_url', $obj->{'start_url'});
		return $res;
	}

	# 初めの一個を生成して返す
	sub first {
		my ($obj) = @_;
		return NgUrl->new($obj, $obj->{'start_url'}, $obj->{'start_url'});
	}

}

################################################################################
# NgUrlのリスト
################################################################################
{
	package NgQueue;

	# items
	# 	itemの配列

	sub new {
		my ($class) = @_;
		my $obj = {'items' => {}, 'garbages' => {}, 'counter' => {}, 'rest' => 0};
		bless $obj, $class;
		return $obj;
	}

	sub exists : locked method {
		my ($obj, $url) = @_;
		my $res = $obj->{'items'}->{$url};
		return $res if ($res);
		return $obj->{'garbages'}->{$url};
	}

	sub find_url : locked method {
		my ($obj) = @_;
		return $obj->exists(@_);
	}

	sub push : locked method {
		my ($obj, $item) = @_;
		return 0 if ($obj->exists($item->{'url'}));
		$obj->{'items'}->{$item->{'url'}} = $item;
		$obj->inc_counter('rest');
		return $item;
	}

	sub pop : locked method {
		my ($obj) = @_;
		my $items = $obj->{'items'};
		my ($key, $poped) = each %$items;
		return 0 unless ($key);
    delete $items->{$key};
		keys %$items;
		$obj->{'garbages'}->{$key} = $poped;
		$obj->dec_counter('rest');
		return $poped;
	}

	sub restore_fail : locked method {
		my ($obj) = @_;
		my $fails = $obj->{'garbages'};
		while (my ($k, $v) = each %$fails) {
			next if $v->{'result'};
			$obj->inc_counter('rest');
			$obj->{'items'}->{$k} = $v;
			delete $fails->{$k};
		}
	}

	sub dec_counter {
		my ($obj, $name) = @_;
		return --$obj->{'counter'}->{$name};
	}

	sub inc_counter {
		my ($obj, $name) = @_;
		return ++$obj->{'counter'}->{$name};
	}

	sub counter {
		my ($obj) = @_;
		return $obj->{'counter'};
	}

	sub get_failed {
		my ($obj) = @_;
		my $fails = $obj->{'garbages'};
		my @res;
		while (my ($k, $v) = each %$fails) {
			push @res, $k unless ($v->{'result'});
		}
		return @res;
	}
	
	
}

################################################################################
# 定数
################################################################################

our $usage = <<'EOT';
nekoget [--url <URL> --dir <PATH>] [--timeout <MSEC>] [--agent <AGENT>] [--retry] [--waonly] [--nowa] [--wafrom <DATE>] [--wato <DATE>]
EOT

################################################################################
# めいん
################################################################################

{

	########################################
	# OPTIONS 
	########################################

	my ($o_url, $o_dir, $o_timeout, $o_agent, $o_kaiko, $o_silent, $o_stdin, $o_nowa, $o_retry, $o_waonly, $o_wafrom, $o_wato);
	
	my $ropt = GetOptions(
		'--url=s' => \$o_url,
		'--dir=s' => \$o_dir,
		'--silent' => \$o_silent,
		'--stdin' => \$o_stdin,
		'--timeout=i' => \$o_timeout,
		'--agent=s' => \$o_agent,
		'--waonly' => \$o_waonly,
		'--nowa' => \$o_nowa,
		'--retry' => \$o_retry,
		'--wafrom=i' => \$o_wafrom,
		'--wato=i' => \$o_wato,
		'--kaiko' => \$o_kaiko
	);

	unless ($o_stdin or ($ropt and $o_url and $o_dir)) {
		print $usage;
		exit;
	}

  unless ($o_dir =~ /\/$/) {
    $o_dir .= "/";
  }

	Ng::timeout($o_timeout);
	Ng::agent($o_agent);
	Ng::debug($o_kaiko);
	

	########################################
	# FIRST
	########################################

	my $queue  = NgQueue->new();
	if ($o_stdin) {
		my $item = {};
		while (<STDIN>) {
			chomp;
			if (m/^\.$/) {
				$item->{'queue'} = $queue;
				$item = NgItem->new($item);
				print "OK\n"; 
				print "error\n" unless (not $o_silent and $item);
				$item = {};
				next;
			}
			my ($k, $v) = m/([^=\s].+)\s*\=\s*([^\s]*)/;
			next unless ($k);
			$k =~ s/dir/store_dir/i;
			$k =~ s/url/start_url/i;
			$v = URI->new($v) if ($k eq 'start_url');
			$item->{$k} = $v;
		}
	} else {
			my $item = {
				'start_url' => URI->new($o_url),
				'store_dir' => $o_dir,
				'queue' => $queue,
			};
		$item = NgItem->new($item);
		$item->{'agent'} = $o_agent;
		$item->{'timeout'} = $o_timeout;
		$item->{'nowa'} = $o_nowa;
		$item->{'retry'} = $o_retry;
		$item->{'waonly'} = $o_waonly;
		$item->{'wafrom'} = $o_wafrom;
		$item->{'wato'} = $o_wato;
	}


	########################################
	# KAIKO
	########################################

	print <<'EOC' unless ($o_silent);
                                                                __
          _____________________________________________________/＿|
        ／                                                        |
   ／￣￣￣￣￣￣|  †    n    e    k    o    g    e    t    †   |
  |      │      |______________________________________________＿|
  |      │      |         ＼               4
～|    ─┼─    |  T N B M  | _＿＿＿＿く∧ﾉ∧>
  |      │       ＼_＿＿＿＿||         ミφーﾟ彡  ＜ ｵｱｰ
   ＼＿＿＿＿＿＿＿＿＿＿＿＿_____＿＿____＿_＿＼   
   ／￣￣￣￣￣￣￣￣￣＼    ／￣￣￣￣￣￣￣￣￣＼  
   ／￣￣￣￣￣￣￣￣￣＼    ／￣￣￣￣￣￣￣￣￣＼
  |◎◎◎◎◎◎◎◎◎◎◎|  |◎◎◎◎◎◎◎◎◎◎◎|
   ＼_＿＿_＿＿___＿＿_／    ＼_＿_＿＿_＿＿_____／

EOC

	########################################
	# LOOOOOP
	########################################

	do {
	
		########################################
		# MAIN
		########################################

		while (my $next = $queue->pop()) {
			my $res = $next->get();
			$queue->inc_counter(Ng::def($res, 'fail'));
			next if ($o_silent);
			print
				$next->{'url'} . "\n" .
				"\t>> " . $next->filename . "\n" .
				"\t>> $res\n" .
				"\t>>"
			;
			my $counter = $queue->counter;
			while (my ($k, $v) = each %$counter) {
				print " $k:$v";
			}
			print "\n\n";
		}

		########################################
		# FAILED
		########################################

		my @fails = $queue->get_failed;
		if (@fails) {
			print "##  FAIL (" . scalar(@fails) . ")\n";
			print "$_\n" for (@fails);
			print('retry? (y/n) : ');	
			while (<>) {
				last if m/^no?$/i;
				next unless m/^ye?s?$/i;
				$queue->restore_fail;
				last;
			}
		}

	} while $queue->counter->{'rest'};

}


