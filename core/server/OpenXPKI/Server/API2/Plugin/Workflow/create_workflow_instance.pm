package OpenXPKI::Server::API2::Plugin::Workflow::create_workflow_instance;
use OpenXPKI::Server::API2::EasyPlugin;

=head1 NAME

OpenXPKI::Server::API2::Plugin::Workflow::create_workflow_instance

=cut

# Project modules
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::API2::Types;
use OpenXPKI::Server::API2::Plugin::Workflow::Util;



=head1 COMMANDS

=head2 create_workflow_instance

Create a new workflow instance of the given type.

Limitations and requirements:

Each workflow MUST start with a state called I<INITIAL> and MUST have exactly
one action. The factory presets the context value for I<creator> with the
current session user, the inital action SHOULD set the context value I<creator>
to the ID of the (associated) user of this workflow if this differs from the
system user. Note that the creator is afterwards attached as a workflow
attribute and will not be updated if you change the context value later on.

Workflows that fail to complete the I<INITIAL> action are not saved and can not
be continued.

B<Parameters>

=over

=item * C<workflow> I<Str> - workflow name

=item * C<params> I<HashRef> - workflow parameters. Optional, default: {}

=item * C<ui_info> I<Bool> - set to 1 to also return detail informations about
the workflow that can be used in the UI

=back

=cut
command "create_workflow_instance" => {
    workflow => { isa => 'AlphaPunct', required => 1, },
    params   => { isa => 'HashRef', default => sub { {} } },
    ui_info  => { isa => 'Bool', default => 0, },
} => sub {
    my ($self, $params) = @_;
    my $type = $params->workflow;

    my $util = OpenXPKI::Server::API2::Plugin::Workflow::Util->new;

    my $workflow = CTX('workflow_factory')->get_factory->create_workflow($type)
        or OpenXPKI::Exception->throw (
            message => "Could not start workflow (type might be unknown)",
            params => { type => $type }
        );

    $workflow->reload_observer;

    ## init creator
    my $id = $workflow->id;

    Log::Log4perl::MDC->put('wfid',   $id);
    Log::Log4perl::MDC->put('wftype', $type);

    my $context = $workflow->context;
    my $creator = CTX('session')->data->user;
    $context->param('creator'      => $creator);
    $context->param('creator_role' => CTX('session')->data->role);

    # This is crucial and must be done before the first execute as otherwise
    # workflow ACLs fails when the first non-initial action is autorun
    $workflow->attrib({ creator => $creator });

    OpenXPKI::Server::Context::setcontext({ workflow_id => $id, force => 1 });

    ##! 16: 'workflow id ' .  $wf_id
    CTX('log')->workflow->info("Workflow instance $id created for $creator (type: '$type')");

    # load the first state and check for the initial action
    my $state = undef;

    my @actions = $workflow->get_current_actions;
    if (scalar @actions != 1) {
        OpenXPKI::Exception->throw (
            message => "Workflow definition does not specify exactly one first activity",
            params => { type => $type }
        );
    }
    my $initial_action = shift @actions;

    ##! 8: "initial action: " . $initial_action

    # check the input params
    my $wf_params = $util->validate_input_params($workflow, $initial_action, $params->params);
    ##! 16: ' initial params ' . Dumper  $wf_params

    $context->param($wf_params) if $wf_params;

    ##! 64: Dumper $workflow

    $util->execute_activity($workflow, $initial_action);

    # FIXME - ported from old factory but I do not understand if this ever can happen..
    # From theory, the workflow should throw an exception if the action can not be handled
    # Workflow is still in initial state - so something went wrong.
    if ($workflow->state eq 'INITIAL') {
        OpenXPKI::Exception->throw (
            message => "Failed to create workflow instance!",
            log =>  {
                priority => 'error',
                facility => 'workflow'
            }
        );
    }

    # check back for the creator in the context and copy it to the attribute table
    # doh - somebody deleted the creator from the context
    $context->param('creator' => $creator) unless $context->param('creator');
    $workflow->attrib({ creator => $context->param('creator') });

    # TODO - we need to persist the workflow here again!

    Log::Log4perl::MDC->put('wfid',   undef);
    Log::Log4perl::MDC->put('wftype', undef);

    if ($params->ui_info) {
        return $util->get_ui_info(workflow => $workflow);
    }
    else {
        return $util->get_workflow_info($workflow);
    }
};

__PACKAGE__->meta->make_immutable;
