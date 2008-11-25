package ActionStreams::Plugin;

use strict;
use warnings;

use Carp qw( croak );
use MT::Util qw( relative_date offset_time epoch2ts ts2epoch format_ts );

sub users_content_nav {
    my ($cb, $app, $html_ref) = @_;

    $$html_ref =~ s{class=["']active["']}{}xmsg
        if $app->mode eq 'list_profileevent' || $app->mode eq 'other_profiles';

    $$html_ref =~ m{ "> ((?:<b>)?) <__trans \s phrase="Permissions"> ((?:</b>)?) </a> }xms;
    my ($open_bold, $close_bold) = ($1, $2);

    my $html = <<"EOF";
    <mt:if var="USER_VIEW">
        <li><a href="<mt:var name="SCRIPT_URL">?__mode=other_profiles&amp;id=<mt:var name="EDIT_AUTHOR_ID">">$open_bold<__trans phrase="Other Profiles">$close_bold</a></li>
        <li><a href="<mt:var name="SCRIPT_URL">?__mode=list_profileevent&amp;id=<mt:var name="EDIT_AUTHOR_ID">">$open_bold<__trans phrase="Action Stream">$close_bold</a></li>
    </mt:if>
    <mt:if var="edit_author">
        <li<mt:if name="other_profiles"> class="active"</mt:if>><a href="<mt:var name="SCRIPT_URL">?__mode=other_profiles&amp;id=<mt:var name="id">">$open_bold<__trans phrase="Other Profiles">$close_bold</a></li>
        <li<mt:if name="list_profileevent"> class="active"</mt:if>><a href="<mt:var name="SCRIPT_URL">?__mode=list_profileevent&amp;id=<mt:var name="id">">$open_bold<__trans phrase="Action Stream">$close_bold</a></li>
    </mt:if>
EOF

    $$html_ref =~ s{(?=</ul>)}{$html}xmsg;
}

sub icon_url_for_service {
    my $class = shift;
    my ($type, $ndata) = @_;

    my $plug = $ndata->{plugin} or return;

    my $icon_url;

    if ($ndata->{icon} && $ndata->{icon} =~ m{ \A \w:// }xms) {
        $icon_url = $ndata->{icon};
    }
    elsif ($ndata->{icon}) {
        $icon_url = MT->app->static_path . join q{/}, $plug->envelope,
            $ndata->{icon};
    }
    elsif ($plug->id eq 'actionstreams') {
        $icon_url = MT->app->static_path . join q{/}, $plug->envelope,
            'images', 'services', $type . '.png';
    }

    return $icon_url;
}

sub list_profileevent {
    my $app = shift;
    my %param = @_;

    $app->return_to_dashboard( redirect => 1 ) if $app->param('blog_id');

    my $author_id = $app->param('id')
        or return;
    return $app->error('Not permitted to view')
        if $app->user->id != $author_id && !$app->user->is_superuser();

    my %service_styles;
    my @service_styles_loop;

    my $code = sub {
        my ($event, $row) = @_;

        my @meta_col = keys %{ $event->properties->{meta_columns} || {} };
        $row->{$_} = $event->{$_} for @meta_col;

        $row->{as_html} = $event->as_html();

        my ($service, $stream_id) = split /_/, $row->{class}, 2;
        $row->{type} = $service;

        my $nets = $app->registry('profile_services') || {};
        my $net = $nets->{$service};
        $row->{service} = $net->{name} if $net;

        $row->{url} = $event->url;

        if (!$service_styles{$service}) {
            if (!$net->{plugin} || $net->{plugin}->id ne 'actionstreams') {
                if (my $icon = __PACKAGE__->icon_url_for_service($service, $net)) {
                    push @service_styles_loop, {
                        service_type => $service,
                        service_icon => $icon,
                    };
                }
            }
            $service_styles{$service} = 1;
        }

        my $ts = $row->{created_on};
        $row->{created_on_relative} = relative_date($ts, time);
        $row->{created_on_formatted} = format_ts(
            MT::App::CMS->LISTING_DATETIME_FORMAT(),
            epoch2ts(undef, offset_time(ts2epoch(undef, $ts))),
            undef,
            $app->user ? $app->user->preferred_language : undef,
        );
    };

    # Make sure all classes are loaded.
    require ActionStreams::Event;
    for my $prevt (keys %{ $app->registry('action_streams') }) {
        ActionStreams::Event->classes_for_type($prevt);
    }

    my $plugin = MT->component('ActionStreams');
    my %params = map { $_ => $app->param($_) ? 1 : 0 }
        qw( saved_deleted hidden shown );

    $params{services} = [];
    my $services = $app->registry('profile_services');
    while (my ($prevt, $service) = each %$services) {
        push @{ $params{services} }, {
            service_id   => $prevt,
            service_name => $service->{name},
        };
    }
    $params{services} = [ sort { lc $a->{service_name} cmp lc $b->{service_name} } @{ $params{services} } ];

    my %terms = (
        class => '*',
        author_id => $author_id,
    );
    my %args = (
        sort => 'created_on',
        direction => 'descend',
    );

    if (my $filter = $app->param('filter')) {
        $params{filter_key} = $filter;
        my $filter_val = $params{filter_val} = $app->param('filter_val');
        if ($filter eq 'service') {
            $params{filter_label} = $app->translate('Actions from the service [_1]', $app->registry('profile_services')->{$filter_val}->{name});
            $terms{class} = $filter_val . '_%';
            $args{like} = { class => 1 };
        }
        elsif ($filter eq 'visible') {
            $params{filter_label} = ($filter_val eq 'show') ? 'Actions that are shown'
                : 'Actions that are hidden';
            $terms{visible} = $filter_val eq 'show' ? 1 : 0;
        }
    }

    $params{id} = $params{edit_author_id} = $author_id;
    $params{service_styles} = \@service_styles_loop;
    $app->listing({
        type     => 'profileevent',
        terms    => \%terms,
        args     => \%args,
        listing_screen => 1,
        code     => $code,
        template => $plugin->load_tmpl('list_profileevent.tmpl'),
        params   => \%params,
    });
}

sub itemset_hide_events {
    my ($app) = @_;
    $app->validate_magic or return;

    my @events = $app->param('id');

    for my $event_id (@events) {
        my $event = MT->model('profileevent')->load($event_id)
          or next;
        next if $app->user->id != $event->author_id && !$app->user->is_superuser();
        $event->visible(0);
        $event->save;
    }

    $app->add_return_arg( hidden => 1 );
    $app->call_return;
}

sub itemset_show_events {
    my ($app) = @_;
    $app->validate_magic or return;

    my @events = $app->param('id');

    for my $event_id (@events) {
        my $event = MT->model('profileevent')->load($event_id)
          or next;
        next if $app->user->id != $event->author_id && !$app->user->is_superuser();
        $event->visible(1);
        $event->save;
    }

    $app->add_return_arg( shown => 1 );
    $app->call_return;
}

sub _itemset_hide_show_all_events {
    my ($app, $new_visible) = @_;
    $app->validate_magic or return;
    my $event_class = MT->model('profileevent');

    # Really we should work directly from the selected author ID, but as an
    # itemset event we only got some event IDs. So use its.
    my ($event_id) = $app->param('id');
    my $event = $event_class->load($event_id)
        or return $app->error($app->translate('No such event [_1]', $event_id));

    my $author_id = $event->author_id;
    return $app->error('Not permitted to modify')
        if $author_id != $app->user->id && !$app->is_superuser();

    my $driver = $event_class->driver;
    my $stmt = $driver->prepare_statement($event_class, {
        # TODO: include filter value when we have filters
        author_id => $author_id,
        visible   => $new_visible ? 0 : 1,
    });

    my $sql = "UPDATE " . $driver->table_for($event_class) . " SET "
        . $driver->dbd->db_column_name($event_class->datasource, 'visible')
        . " = ? " . $stmt->as_sql_where;

    # Work around error in MT::ObjectDriver::Driver::DBI::sql by doing it inline.
    my $dbh = $driver->rw_handle;
    $dbh->do($sql, {}, $new_visible, @{ $stmt->{bind} })
        or return $app->error($dbh->errstr);

    return 1;
}

sub itemset_hide_all_events {
    my $app = shift;
    _itemset_hide_show_all_events($app, 0) or return;
    $app->add_return_arg( all_hidden => 1 );
    $app->call_return;
}

sub itemset_show_all_events {
    my $app = shift;
    _itemset_hide_show_all_events($app, 1) or return;
    $app->add_return_arg( all_shown => 1 );
    $app->call_return;
}

sub _build_service_data {
    my %info = @_;
    my ($networks, $streams, $author) = @info{qw( networks streams author )};
    my (@service_styles_loop, @networks);

    my %has_profiles;
    if ($author) {
        my $other_profiles = $author->other_profiles();
        $has_profiles{$_->{type}} = 1 for @$other_profiles;
    }

    my @network_keys = sort { lc $networks->{$a}->{name} cmp lc $networks->{$b}->{name} }
        keys %$networks;
    TYPE: for my $type (@network_keys) {
        my $ndata = $networks->{$type}
            or next TYPE;

        my @streams;
        if ($streams) {
            my $streamdata = $streams->{$type} || {};
            @streams =
                sort { lc $a->{name} cmp lc $b->{name} }
                grep { grep { $_ } @$_{qw( class scraper xpath rss atom )} }
                map  { +{ stream => $_, %{ $streamdata->{$_} } } }
                grep { $_ ne 'plugin' }
                keys %$streamdata;
        }

        my $ret = {
            type => $type,
            %$ndata,
            label => $ndata->{name},
            user_has_account => ($has_profiles{$type} ? 1 : 0),
        };
        $ret->{streams} = \@streams if @streams;
        push @networks, $ret;

        if (!$ndata->{plugin} || $ndata->{plugin}->id ne 'actionstreams') {
            push @service_styles_loop, {
                service_type => $type,
                service_icon => __PACKAGE__->icon_url_for_service($type, $ndata),
            };
        }
    }

    return (
        service_styles => \@service_styles_loop,
        networks       => \@networks,
    );
}

sub upgrade_enable_existing_streams {
    my ($author) = @_;
    my $app = MT->app;

    my $profiles = $author->other_profiles();
    return if !$profiles || !@$profiles;

    for my $profile (@$profiles) {
        my $type = $profile->{type};
        my $streams = $app->registry('action_streams', $type);
        $profile->{streams} = { map { join(q{_}, $type, $_) => 1 } keys %$streams };
    }

    $author->meta( other_profiles => $profiles );
    $author->save;
}

sub upgrade_reclass_actions {
    my ($upg, %param) = @_;

    my $action_class = MT->model('profileevent');
    my $driver = $action_class->driver;
    my $dbd = $driver->dbd;
    my $dbh = $driver->rw_handle;
    my $class_col = $dbd->db_column_name($action_class->datasource, 'class');

    my %reclasses = (
        'twitter_tweets' => 'twitter_statuses',
        'pownce_notes'   => 'pownce_statuses',
    );

    my $app      = MT->instance;
    my $plugin   = MT->component('ActionStreams');
    my $services = $app->registry('profile_services');
    my $streams  = $app->registry('action_streams');
    while (my ($old_class, $new_class) = each %reclasses) {
        my ($service, $stream) = split /_/, $new_class, 2;
        $upg->progress($plugin->translate('Updating classification of [_1] [_2] actions...',
            $services->{$service}->{name}, $streams->{$service}->{$stream}->{name}));

        my $stmt = $dbd->sql_class->new;
        $stmt->add_where( $class_col => $old_class );
        my $sql = join q{ }, 'UPDATE', $driver->table_for($action_class),
            'SET', $class_col, '= ?', $stmt->as_sql_where();
        $dbh->do($sql, {}, $new_class, @{ $stmt->{bind} })
            or die $dbh->errstr;
    }

    return 0;  # done
}

sub other_profiles {
    my( $app ) = @_;

    $app->return_to_dashboard( redirect => 1 ) if $app->param('blog_id');

    my $author_id = $app->param('id')
        or return $app->error('Author id is required');
    my $user = MT->model('author')->load($author_id)
        or return $app->error('Author id is invalid');
    return $app->error('Not permitted to view')
        if $app->user->id != $author_id && !$app->user->is_superuser();

    my $plugin = MT->component('ActionStreams');
    my $tmpl = $plugin->load_tmpl( 'other_profiles.tmpl' );

    my @profiles = sort { lc $a->{label} cmp lc $b->{label} }
        @{ $user->other_profiles || [] };

    my %messages = map { $_ => $app->param($_) ? 1 : 0 }
        (qw( added removed updated edited ));
    return $app->build_page( $tmpl, {
        id             => $user->id,
        edit_author_id => $user->id,
        profiles       => \@profiles,
        listing_screen => 1,
        _build_service_data(
            networks => $app->registry('profile_services'),
        ),
        %messages,
    } );
}

sub dialog_add_edit_profile {
    my ($app) = @_;

    return $app->error('Not permitted to view')
        if $app->user->id != $app->param('author_id') && !$app->user->is_superuser();
    my $author = MT->model('author')->load($app->param('author_id'))
        or return $app->error('No such author [_1]', $app->param('author_id'));

    my %edit_profile;
    my $tmpl_name = 'dialog_add_profile.tmpl';
    if (my $edit_type = $app->param('profile_type')) {
        my $ident = $app->param('profile_ident') || q{};
        my ($profile) = grep { $_->{ident} eq $ident }
            @{ $author->other_profiles($edit_type) };

        %edit_profile = (
            edit_type      => $edit_type,
            edit_type_name => $app->registry('profile_services', $edit_type, 'name'),
            edit_ident     => $ident,
            edit_streams   => $profile->{streams} || [],
        );

        $tmpl_name = 'dialog_edit_profile.tmpl';
    }

    my $plugin = MT->component('ActionStreams');
    my $tmpl = $plugin->load_tmpl($tmpl_name);

    return $app->build_page($tmpl, {
        edit_author_id => $app->param('author_id'),
        _build_service_data(
            networks => $app->registry('profile_services'),
            streams  => $app->registry('action_streams'),
            author   => $author,
        ),
        %edit_profile,
    });
}

sub edit_other_profile {
    my $app = shift;
    $app->validate_magic() or return;

    my $author_id = $app->param('author_id')
        or return $app->error('Author id is required');
    my $user = MT->model('author')->load($author_id)
        or return $app->error('Author id is invalid');
    return $app->error('Not permitted to edit')
        if $app->user->id != $author_id && !$app->user->is_superuser();

    my $type = $app->param('profile_type');
    my $orig_ident = $app->param('original_ident');

    $user->remove_profile($type, $orig_ident);

    $app->forward('add_other_profile', success_msg => 'edited');
}

sub add_other_profile {
    my $app = shift;
    my %param = @_;
    $app->validate_magic or return;

    my $author_id = $app->param('author_id')
        or return $app->error('Author id is required');
    my $user = MT->model('author')->load($author_id)
        or return $app->error('Author id is invalid');
    return $app->error('Not permitted to add')
        if $app->user->id != $author_id && !$app->user->is_superuser();

    my( $ident, $uri, $label, $type );
    if ( $type = $app->param( 'profile_type' ) ) {
        my $reg = $app->registry('profile_services');
        my $network = $reg->{$type}
            or croak "Unknown network $type";
        $label = $network->{name} . ' Profile';

        $ident = $app->param( 'profile_id' );
        $ident =~ s{ \A \s* }{}xms;
        $ident =~ s{ \s* \z }{}xms;

        # Check for full URLs.
        if (!$network->{ident_exact}) {
            my $url_pattern = $network->{url};
            my ($pre_ident, $post_ident) = split /(?:\%s|\Q{{ident}}\E)/, $url_pattern, 2;
            $pre_ident =~ s{ \A http:// }{}xms;
            $post_ident =~ s{ / \z }{}xms;
            if ($ident =~ m{ \A (?:http://)? \Q$pre_ident\E (.*?) \Q$post_ident\E /? \z }xms) {
                $ident = $1;
            }
        }

        $uri = $network->{url};
        $uri =~ s{ (?:\%s|\Q{{ident}}\E) }{$ident}xmsg;
    } else {
        $ident = $uri = $app->param( 'profile_uri' );
        $label = $app->param( 'profile_label' );
        $type = 'website';
    }

    my $profile = {
        type    => $type,
        ident   => $ident,
        label   => $label,
        uri     => $uri,
    };

    my %streams = map { join(q{_}, $type, $_) => 1 }
        grep { $_ ne 'plugin' && $app->param(join q{_}, 'stream', $type, $_) }
        keys %{ $app->registry('action_streams', $type) || {} };
    $profile->{streams} = \%streams if %streams;

    $app->run_callbacks('pre_add_profile.'  . $type, $app, $user, $profile);
    $user->add_profile($profile);
    $app->run_callbacks('post_add_profile.' . $type, $app, $user, $profile);

    my $success_msg = $param{success_msg} || 'added';
    return $app->redirect($app->uri(
        mode => 'other_profiles',
        args => { id => $author_id, $success_msg => 1 },
    ));
}

sub remove_other_profile {
    my( $app ) = @_;
    $app->validate_magic or return;

    my %users;
    my $page_author_id;
    PROFILE: for my $profile ($app->param('id')) {
        my ($author_id, $type, $ident) = split /:/, $profile, 3;

        my $user = ($users{$author_id} ||= MT->model('author')->load($author_id))
            or next PROFILE;
        next PROFILE
            if $app->user->id != $author_id && !$app->user->is_superuser();

        $app->run_callbacks('pre_remove_profile.'  . $type, $app, $user, $type, $ident);
        $user->remove_profile( $type, $ident );
        $app->run_callbacks('post_remove_profile.' . $type, $app, $user, $type, $ident);
        $page_author_id = $author_id;
    }

    return $app->redirect($app->uri(
        mode => 'other_profiles',
        args => { id => ($page_author_id || $app->user->id), removed => 1 },
    ));
}

sub itemset_update_profiles {
    my $app = shift;

    my %users;
    my $page_author_id;
    PROFILE: for my $profile ($app->param('id')) {
        my ($author_id, $type, $ident) = split /:/, $profile, 3;

        my $user = ($users{$author_id} ||= MT->model('author')->load($author_id))
            or next PROFILE;
        next PROFILE
            if $app->user->id != $author_id && !$app->user->is_superuser();

        my $profiles = $user->other_profiles($type);
        if (!$profiles) {
            next PROFILE;
        }
        my @profiles = grep { $_->{ident} eq $ident } @$profiles;
        for my $author_profile (@profiles) {
            update_events_for_profile($user, $author_profile,
                synchronous => 1);
        }

        $page_author_id ||= $author_id;
    }

    return $app->redirect($app->uri(
        mode => 'other_profiles',
        args => { id => ($page_author_id || $app->user->id), updated => 1 },
    ));
}

sub first_profile_update {
    my ($cb, $app, $user, $profile) = @_;
    update_events_for_profile($user, $profile,
        synchronous => 1, hide_timeless => 1);
}

sub rebuild_action_stream_blogs {
    my ($cb, $app) = @_;

    my $plugin = MT->component('ActionStreams');
    my $pd_iter = MT->model('plugindata')->load_iter({
        plugin => $plugin->key,
        key => { like => 'configuration:blog:%' }
    });
    my %rebuild;
    while ( my $pd = $pd_iter->() ) {
        next unless $pd->data('rebuild_for_action_stream_events');
        my ($blog_id) = $pd->key =~ m/:blog:(\d+)$/;
        $rebuild{$blog_id} = 1;
    }
    foreach my $blog_id (keys %rebuild) {
        # FIXME: We could possibly limit this further so we only rebuild
        # indexes that use actionstreams...
        my $blog = MT->model('blog')->load( $blog_id ) or next;
        $app->rebuild_indexes( Blog => $blog );
    }
}

sub widget_recent {
    my ($app, $tmpl, $widget_param) = @_;
    $tmpl->param('author_id', $app->user->id);
    $tmpl->param('blog_id', $app->blog->id) if $app->blog;
}

sub widget_blog_dashboard_only {
    my ($page, $scope) = @_;
    return if $scope eq 'dashboard:system';
    return 1;
}

sub update_events {
    my $mt = MT->app;
    $mt->run_callbacks('pre_action_streams_task', $mt);

    my $au_class = MT->model('author');
    my $author_iter = $au_class->search({
        type   => $au_class->AUTHOR(),
        status => $au_class->ACTIVE(),
    });
    while (my $author = $author_iter->()) {
        my $profiles = $author->other_profiles();
        $mt->run_callbacks('pre_update_action_streams',  $mt, $author, $profiles);

        PROFILE: for my $profile (@$profiles) {
            update_events_for_profile($author, $profile);
        }

        $mt->run_callbacks('post_update_action_streams', $mt, $author, $profiles);
    }

    $mt->run_callbacks('post_action_streams_task', $mt);
}

sub update_events_for_profile {
    my ($author, $profile, %param) = @_;
    my $type = $profile->{type};
    my $streams = $profile->{streams};
    return if !$streams || !%$streams;

    require ActionStreams::Event;
    my @event_classes = ActionStreams::Event->classes_for_type($type)
      or return;

    my $mt = MT->app;
    $mt->run_callbacks('pre_update_action_streams_profile.' . $profile->{type},
        $mt, $author, $profile);
    EVENTCLASS: for my $event_class (@event_classes) {
        next EVENTCLASS if !$streams->{$event_class->class_type};

        if ($param{synchronous}) {
            $event_class->update_events_safely(
                author        => $author,
                hide_timeless => $param{hide_timeless} ? 1 : 0,
                %$profile,
            );
        }
        else {
            # Defer regular updates to job workers.
            require ActionStreams::Worker;
            ActionStreams::Worker->make_work(
                event_class => $event_class,
                author      => $author,
                %$profile,
            );
        }
    }
    $mt->run_callbacks('post_update_action_streams_profile.' . $profile->{type},
        $mt, $author, $profile);
}

1;

