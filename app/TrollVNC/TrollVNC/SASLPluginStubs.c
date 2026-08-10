/*
  SASLPluginStubs.c - no-op SASL built-in plugin stubs

  The vendored libsasl2.a is a static build whose dlopen.o references its
  built-in plugin entry points (_*_plug_init). Those plugins are not compiled
  into this slim library, so any binary that pulls in dlopen.o (e.g. the app,
  via libvncclient's SASL client path) hits undefined symbols at link time.

  Provide minimal stubs returning SASL_NOMECH (-12, "no mechanism") so the
  link succeeds. This build does not rely on SASL authentication, so the
  stubs are never exercised in practice.
*/

/* SASL_NOMECH */
#define TR_SASL_NOMECH (-12)

#define TR_SASL_PLUGIN_STUB(name)           \
    int name(void) {                        \
        (void)0;                            \
        return TR_SASL_NOMECH;              \
    }

TR_SASL_PLUGIN_STUB(anonymous_client_plug_init)
TR_SASL_PLUGIN_STUB(anonymous_server_plug_init)
TR_SASL_PLUGIN_STUB(otp_client_plug_init)
TR_SASL_PLUGIN_STUB(otp_server_plug_init)
TR_SASL_PLUGIN_STUB(plain_client_plug_init)
TR_SASL_PLUGIN_STUB(plain_server_plug_init)
TR_SASL_PLUGIN_STUB(scram_client_plug_init)
TR_SASL_PLUGIN_STUB(scram_server_plug_init)
TR_SASL_PLUGIN_STUB(sasldb_auxprop_plug_init)
