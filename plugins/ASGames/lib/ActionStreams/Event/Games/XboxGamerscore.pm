
package ActionStreams::Event::Games::XboxGamerscore;

use strict;
use base qw( ActionStreams::Event );

use Web::Scraper;

__PACKAGE__->install_properties({
    class_type => 'xboxlive_gamerscore',
});

__PACKAGE__->install_meta({
    columns => [ qw(
        score
        ident
    ) ],
});

sub as_html {
    my $event = shift;
    return MT->translate('[_1] exceeded <strong>[_2]</strong> gamerscore <a href="[_3]">on Xbox Live</a>',
        MT::Util::encode_html($event->author->nickname),
        map { MT::Util::encode_html($event->$_()) } qw( score url ));
}

sub update_events {
    my $class = shift;
    my %profile = @_;
    my ($ident, $author) = @profile{qw( ident author )};

    my $url = "http://gamercard.xbox.com/$ident.card";

    my $scraper = scraper {
        process q{//img[@alt='Gamerscore']/ancestor::p/span[@class='XbcFRAR']},
            score => 'TEXT';
    };
    $scraper->user_agent($class->ua);
    my $score = $scraper->scrape(URI->new($url));
    return if !$score;

    $score = $score->{score};
    require Scalar::Util;
    return if !Scalar::Util::looks_like_number($score);

    $score =~ s/ (?<= \A \d ) (\d*) \z / join q{}, ((q{0}) x length $1) /xmse;

    my $item = {
        url        => "http://live.xbox.com/member/$ident",
        score      => $score;
        identifier => join(q{:}, $ident, $score),
    };

    $class->build_results( author => $author, items => [ $item ] );
}

1;
