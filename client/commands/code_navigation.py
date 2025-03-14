# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
This command contains the main logic for the client connecting language servers
and Pyre's code navigation server. It mainly ferries LSP requests back and forth between
editors and the backend, and handles the initialization protocol and searches for appropriate
configurations.
"""

from __future__ import annotations

import asyncio
import json
import logging
import traceback

from typing import Optional

from .. import timer, version
from ..language_server import connections, features, protocol as lsp

from . import (
    backend_arguments,
    background,
    initialization,
    launch_and_subscribe_handler,
    log_lsp_event,
    persistent,
    pyre_language_server,
    pyre_server_options,
    request_handler,
    server_state as state,
    subscription,
)

LOG: logging.Logger = logging.getLogger(__name__)

READY_MESSAGE: str = "Pyre's code navigation server has completed an incremental check and is currently watching on further source changes."
READY_SHORT: str = "Pyre CodeNav Ready"


async def _read_server_response(
    server_input_channel: connections.AsyncTextReader,
) -> str:
    return await server_input_channel.read_until(separator="\n")


class PyreCodeNavigationSubscriptionResponseParser(
    launch_and_subscribe_handler.PyreSubscriptionResponseParser
):
    def parse_response(self, response: str) -> subscription.Response:
        return subscription.Response.parse_code_navigation_response(response)


class PyreCodeNavigationDaemonLaunchAndSubscribeHandler(
    launch_and_subscribe_handler.PyreDaemonLaunchAndSubscribeHandler
):
    def __init__(
        self,
        server_options_reader: pyre_server_options.PyreServerOptionsReader,
        server_state: state.ServerState,
        client_status_message_handler: persistent.ClientStatusMessageHandler,
        client_type_error_handler: persistent.ClientTypeErrorHandler,
        request_handler: request_handler.AbstractRequestHandler,
        remote_logging: Optional[backend_arguments.RemoteLogging] = None,
    ) -> None:
        super().__init__(
            server_options_reader,
            server_state,
            client_status_message_handler,
            client_type_error_handler,
            PyreCodeNavigationSubscriptionResponseParser(),
            request_handler,
            remote_logging,
        )

    def get_type_errors_availability(self) -> features.TypeErrorsAvailability:
        return self.server_state.server_options.language_server_features.type_errors

    async def handle_type_error_subscription(
        self, type_error_subscription: subscription.TypeErrors
    ) -> None:
        # We currently do not broadcast any type errors on the CodeNav server - the intent is to be
        # as lazy as possible and only provide actionable information to users. The error is intended
        # to demonstrate that contract.
        raise RuntimeError(
            "The Pyre code navigation server is not expected to broadcast type errors at the moment."
        )

    async def handle_status_update_subscription(
        self, status_update_subscription: subscription.StatusUpdate
    ) -> None:
        if not self.get_type_errors_availability().is_disabled():
            await self.client_type_error_handler.clear_type_errors_for_client()
        if status_update_subscription.kind == "Stop":
            self.server_state.server_last_status = state.ServerStatus.DISCONNECTED
            self.client_status_message_handler.log(
                "The Pyre code-navigation server has stopped.",
                short_message="Pyre code-nav (stopped)",
                level=lsp.MessageType.WARNING,
            )
            raise launch_and_subscribe_handler.PyreDaemonShutdown(
                status_update_subscription.message or ""
            )
        elif status_update_subscription.kind == "BusyChecking":
            self.server_state.server_last_status = state.ServerStatus.INCREMENTAL_CHECK
            self.client_status_message_handler.log(
                "The Pyre code-navigation server is busy re-type-checking the project...",
                short_message="Pyre code-nav (checking)",
                level=lsp.MessageType.WARNING,
            )
        elif status_update_subscription.kind == "Idle":
            self.server_state.server_last_status = state.ServerStatus.READY
            self.client_status_message_handler.log(
                READY_MESSAGE,
                short_message=READY_SHORT,
                level=lsp.MessageType.INFO,
            )

    async def handle_error_subscription(
        self, error_subscription: subscription.Error
    ) -> None:
        message = error_subscription.message
        LOG.info(f"Received error from subscription channel: {message}")
        raise launch_and_subscribe_handler.PyreDaemonShutdown(message)

    async def _subscribe(
        self,
        server_input_channel: connections.AsyncTextReader,
        server_output_channel: connections.AsyncTextWriter,
    ) -> None:
        subscription_name = "code_navigation"
        await server_output_channel.write('["Subscription", ["Subscribe"]]\n')
        first_response = await _read_server_response(server_input_channel)
        if json.loads(first_response) != ["Ok"]:
            raise ValueError(
                f"Unexpected server response to Subscription: {first_response!r}"
            )
        await self._run_subscription_loop(
            subscription_name,
            server_input_channel,
            server_output_channel,
        )

    async def send_open_state(self) -> None:
        results = await asyncio.gather(
            *[
                self.request_handler.handle_file_opened(path, document.code)
                for path, document in self.server_state.opened_documents.items()
            ]
        )
        if len(results) > 0:
            LOG.info(f"Sent {len(results)} open messages to daemon for existing state.")


def process_initialize_request(
    parameters: lsp.InitializeParameters,
    language_server_features: Optional[features.LanguageServerFeatures] = None,
) -> lsp.InitializeResult:
    LOG.info(
        f"Received initialization request from {parameters.client_info} "
        f" (pid = {parameters.process_id})"
    )
    if language_server_features is None:
        language_server_features = features.LanguageServerFeatures()
    server_info = lsp.Info(name="pyre-codenav", version=version.__version__)
    server_capabilities = lsp.ServerCapabilities(
        text_document_sync=lsp.TextDocumentSyncOptions(
            open_close=True,
            change=lsp.TextDocumentSyncKind.FULL,
            save=lsp.SaveOptions(include_text=False),
        ),
        **language_server_features.capabilities(),
    )
    return lsp.InitializeResult(
        capabilities=server_capabilities, server_info=server_info
    )


async def async_run_code_navigation_client(
    server_options_reader: pyre_server_options.PyreServerOptionsReader,
    remote_logging: Optional[backend_arguments.RemoteLogging],
) -> int:
    initial_server_options = launch_and_subscribe_handler.PyreDaemonLaunchAndSubscribeHandler.read_server_options(
        server_options_reader, remote_logging
    )
    stdin, stdout = await connections.create_async_stdin_stdout()
    initialize_result = await initialization.async_try_initialize_loop(
        initial_server_options,
        stdin,
        stdout,
        remote_logging,
        process_initialize_request,
    )
    if isinstance(initialize_result, initialization.InitializationExit):
        return 0
    client_info = initialize_result.client_info
    log_lsp_event._log_lsp_event(
        remote_logging=remote_logging,
        event=log_lsp_event.LSPEvent.INITIALIZED,
        normals=(
            {}
            if client_info is None
            else {
                "lsp client name": client_info.name,
                "lsp client version": client_info.version,
            }
        ),
    )

    client_capabilities = initialize_result.client_capabilities
    LOG.debug(f"Client capabilities: {client_capabilities}")
    server_state = state.ServerState(
        client_capabilities=client_capabilities,
        server_options=initial_server_options,
    )
    handler = request_handler.CodeNavigationRequestHandler(server_state=server_state)
    server = pyre_language_server.PyreLanguageServer(
        input_channel=stdin,
        output_channel=stdout,
        server_state=server_state,
        daemon_manager=background.TaskManager(
            PyreCodeNavigationDaemonLaunchAndSubscribeHandler(
                server_options_reader=server_options_reader,
                remote_logging=remote_logging,
                server_state=server_state,
                client_status_message_handler=persistent.ClientStatusMessageHandler(
                    stdout, server_state
                ),
                request_handler=handler,
                client_type_error_handler=persistent.ClientTypeErrorHandler(
                    stdout, server_state, remote_logging
                ),
            )
        ),
        handler=handler,
    )
    return await server.run()


def run(
    server_options_reader: pyre_server_options.PyreServerOptionsReader,
    remote_logging: Optional[backend_arguments.RemoteLogging],
) -> int:
    command_timer = timer.Timer()
    error_message: Optional[str] = None
    try:
        return asyncio.run(
            async_run_code_navigation_client(
                server_options_reader,
                remote_logging,
            )
        )
    except Exception:
        error_message = traceback.format_exc()
        LOG.exception("Uncaught error in code_navigation.run")
        return 1
    finally:
        log_lsp_event._log_lsp_event(
            remote_logging,
            log_lsp_event.LSPEvent.STOPPED,
            integers={"duration": int(command_timer.stop_in_millisecond())},
            normals={
                **({"exception": error_message} if error_message is not None else {})
            },
        )
