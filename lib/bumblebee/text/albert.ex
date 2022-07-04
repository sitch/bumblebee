defmodule Bumblebee.Text.Albert do
  @common_keys [:output_hidden_states, :output_attentions, :id2label, :label2id, :num_labels]

  @moduledoc """
  Models based on the ALBERT architecture.

  ## Architectures

    * `:base` - plain ALBERT without any head on top

    * `:for_masked_language_modeling` - ALBERT with a language modeling
      head. The head returns logits for each token in the original
      sequence

    * `:for_causal_language_modeling` - ALBERT with a language modeling
      head. The head returns logits for each token in the original
      sequence

    * `:for_sequence_classification` - ALBERT with a sequence
      classification head. The head returns logits corresponding to
      possible classes

    * `:for_token_classification` - ALBERT with a token classification
      head. The head returns logits for each token in the original
      sequence

    * `:for_question_answering` - ALBERT with a span classification head.
      The head returns logits for the span start and end positions

    * `:for_multiple_choice` - ALBERT with a multiple choice prediction
      head. Each input in the batch consists of several sequences to
      choose from and the model returns logits corresponding to those
      choices

    * `:for_pre_training` - ALBERT with both MLM and NSP heads as done
      during the pre-training

  ## Inputs

    * `"input_ids"` - indices of input sequence tokens in the vocabulary

    * `"attention_mask"` - a mask indicating which tokens to attend to.
      This is used to ignore padding tokens, which are added when
      processing a batch of sequences with different length

    * `"token_type_ids"` - a mask distinguishing groups in the input
      sequence. This is used in when the input sequence is a semantically
      a pair of sequences

    * `"position_ids"` - indices of positions of each input sequence
      tokens in the position embeddings

  ## Configuration

    * `:vocab_size` - vocabulary size of the model. Defines the number
      of distinct tokens that can be represented by the in model input
      and output. Defaults to `30000`

    * `:embedding_size` - dimensionality of vocab embeddings. Defaults
      to 128

    * `:hidden_size` - dimensionality of the encoder layers and the
      pooler layer. Defaults to `4096`

    * `:num_hidden_layers` - the number of hidden layers in the
      Transformer encoder. Defaults to `12`

    * `:num_hidden_groups` - the number of groups for hidden layers,
      parameters in the same group are shared. Defaults to `1`

    * `:num_attention_heads` - the number of attention heads for each
      attention layer in the Transformer encoder. Defaults to `12`

    * `:intermediate_size` - dimensionality of the "intermediate"
      (often named feed-forward) layer in the Transformer encoder.
      Defaults to `16384`

    * `:inner_group_num` - number of inner repetition of attention
      and ffn. Defaults to 1

    * `:hidden_act` - the activation function in the encoder and
      pooler. Defaults to `:gelu`

    * `:hidden_dropout_prob` - the dropout probability for all fully
      connected layers in the embeddings, encoder, and pooler. Defaults
      to `0.1`

    * `:attention_probs_dropout_prob` - the dropout probability for
      attention probabilities. Defaults to `0.1`

    * `:max_position_embeddings` - the maximum sequence length that this
      model might ever be used with. Typically set this to something
      large just in case (e.g. 512 or 1024 or 2048). Defaults to `512`

    * `:type_vocab_size` - the vocabulary size of the `token_type_ids`
      passed as part of model input. Defaults to `2`

    * `:initializer_range` - the standard deviation of the normal
      initializer used for initializing kernel parameters. Defaults
      to `0.02`

    * `:layer_norm_eps` - the epsilon used by the layer normalization
      layers. Defaults to `1.0e-12`

    * `:classifier_dropout_prob` - the dropout ratio for the classification
      head. If not specified, the value of `:hidden_dropout_prob` is
      used instead

  ### Common options

  #{Bumblebee.Shared.common_config_docs(@common_keys)}
  """

  import Bumblebee.Utils.Model, only: [join: 2]

  alias Bumblebee.Shared
  alias Bumblebee.Layers

  defstruct [
              architecture: :base,
              vocab_size: 30000,
              embedding_size: 128,
              hidden_size: 4096,
              num_hidden_layers: 12,
              num_hidden_groups: 1,
              num_attention_heads: 12,
              intermediate_size: 16384,
              inner_group_num: 1,
              hidden_act: :gelu,
              hidden_dropout_prob: 0.0,
              attention_probs_dropout_prob: 0.0,
              max_position_embeddings: 512,
              type_vocab_size: 2,
              initializer_range: 0.02,
              layer_norm_eps: 1.0e-12,
              classifier_dropout_prob: 0.1,
              position_embedding_type: :absolute,
              pad_token_id: 0,
              bos_token_id: 2,
              eos_token_id: 3
            ] ++ Shared.common_config_defaults(@common_keys)

  @behaviour Bumblebee.ModelSpec

  @impl true
  def base_model_prefix(), do: "albert"

  @impl true
  def architectures(),
    do: [
      :base,
      :for_masked_language_modeling,
      :for_causal_language_modeling,
      :for_sequence_classification,
      :for_token_classification,
      :for_question_answering,
      :for_multiple_choice,
      :for_pre_training
    ]

  @impl true
  def config(config, opts \\ []) do
    opts = Shared.add_common_computed_options(opts)
    Shared.put_config_attrs(config, opts)
  end

  @impl true
  def model(%__MODULE__{architecture: :base} = config) do
    inputs({nil, 11})
    |> albert(config, name: "albert")
    |> Bumblebee.Utils.Model.output(config)
  end

  def model(%__MODULE__{architecture: :for_masked_language_modeling} = config) do
    outputs = inputs({nil, 9}) |> albert(config, name: "albert")

    logits = lm_prediction_head(outputs.last_hidden_state, config, name: "predictions")

    Bumblebee.Utils.Model.output(
      %{
        logits: logits,
        hidden_states: outputs.hidden_states,
        attentions: outputs.attentions
      },
      config
    )
  end

  def model(%__MODULE__{architecture: :for_sequence_classification} = config) do
    outputs = inputs({nil, 9}) |> albert(config, name: "albert")

    logits =
      outputs.pooler_output
      |> Axon.dropout(rate: classifier_dropout_rate(config))
      |> Axon.dense(config.num_labels,
        kernel_initializer: kernel_initializer(config),
        name: "classifier"
      )

    Bumblebee.Utils.Model.output(
      %{
        logits: logits,
        hidden_states: outputs.hidden_states,
        attentions: outputs.attentions
      },
      config
    )
  end

  def model(%__MODULE__{architecture: :for_multiple_choice} = config) do
    inputs = inputs({nil, nil, 9})

    flat_inputs =
      Map.new(inputs, fn {key, input} -> {key, Layers.flatten_leading_layer(input)} end)

    outputs = albert(flat_inputs, config, name: "albert")

    logits =
      outputs.pooler_output
      |> Axon.dropout(rate: classifier_dropout_rate(config), name: "dropout")
      |> Axon.dense(1,
        kernel_initializer: kernel_initializer(config),
        name: "classifier"
      )

    # The final shape depends on the dynamic batch size and number
    # of choices, so we do a custom reshape at runtime
    logits =
      Axon.layer(
        fn logits, input_ids, _opts ->
          num_choices = Nx.axis_size(input_ids, 1)
          Nx.reshape(logits, {:auto, num_choices})
        end,
        [logits, inputs["input_ids"]]
      )

    Bumblebee.Utils.Model.output(
      %{
        logits: logits,
        hidden_states: outputs.hidden_states,
        attentions: outputs.attentions
      },
      config
    )
  end

  def model(%__MODULE__{architecture: :for_token_classification} = config) do
    # TODO: Non-static seq len
    input_shape = {nil, 9}

    outputs =
      input_shape
      |> inputs()
      |> albert(config, name: "albert")

    logits =
      outputs.last_hidden_state
      |> Axon.dropout(rate: classifier_dropout_rate(config))
      |> Axon.dense(config.num_labels,
        kernel_initializer: kernel_initializer(config),
        name: "classifier"
      )

    Bumblebee.Utils.Model.output(
      %{
        logits: logits,
        hidden_states: outputs.hidden_states,
        attentions: outputs.attentions
      },
      config
    )
  end

  def model(%__MODULE__{architecture: :for_question_answering} = config) do
    # TODO: Non-static seq len
    input_shape = {nil, 9}

    outputs =
      input_shape
      |> inputs()
      |> albert(config, name: "albert")

    logits =
      Axon.dense(outputs.last_hidden_state, 2,
        kernel_initializer: kernel_initializer(config),
        name: "qa_outputs"
      )

    start_logits = Axon.nx(logits, & &1[[0..-1//1, 0..-1//1, 0]])
    end_logits = Axon.nx(logits, & &1[[0..-1//1, 0..-1//1, 1]])

    Bumblebee.Utils.Model.output(
      %{
        start_logits: start_logits,
        end_logits: end_logits,
        hidden_states: outputs.hidden_states,
        attentions: outputs.attentions
      },
      config
    )
  end

  defp inputs(input_shape) do
    %{
      "input_ids" => Axon.input(input_shape, "input_ids"),
      "attention_mask" =>
        Axon.input(input_shape, "attention_mask",
          default: fn inputs -> Nx.broadcast(1, inputs["input_ids"]) end
        ),
      "token_type_ids" =>
        Axon.input(input_shape, "token_type_ids",
          default: fn inputs -> Nx.broadcast(0, inputs["input_ids"]) end
        ),
      "position_ids" =>
        Axon.input(input_shape, "position_ids",
          default: fn inputs -> Nx.iota(inputs["input_ids"], axis: -1) end
        )
    }
  end

  defp albert(inputs, config, opts) do
    name = opts[:name]

    hidden_states = embeddings(inputs, config, name: join(name, "embeddings"))

    {last_hidden_state, hidden_states, attentions} =
      encoder(inputs, hidden_states, config, name: join(name, "encoder"))

    pooler_output = pooler(last_hidden_state, config, name: join(name, "pooler"))

    %{
      last_hidden_state: last_hidden_state,
      pooler_output: pooler_output,
      hidden_states: if(config.output_hidden_states, do: hidden_states, else: {}),
      attentions: if(config.output_attentions, do: attentions, else: {})
    }
  end

  defp embeddings(inputs, config, opts) do
    name = opts[:name]

    input_ids = inputs["input_ids"]
    position_ids = inputs["position_ids"]
    token_type_ids = inputs["token_type_ids"]

    inputs_embeds =
      Axon.embedding(input_ids, config.vocab_size, config.embedding_size,
        kernel_initializer: kernel_initializer(config),
        name: name <> ".word_embeddings"
      )

    position_embeds =
      Axon.embedding(position_ids, config.max_position_embeddings, config.embedding_size,
        kernel_initializer: kernel_initializer(config),
        name: name <> ".position_embeddings"
      )

    token_type_embeds =
      Axon.embedding(token_type_ids, config.type_vocab_size, config.embedding_size,
        kernel_initializer: kernel_initializer(config),
        name: name <> ".token_type_embeddings"
      )

    Axon.add([inputs_embeds, position_embeds, token_type_embeds])
    |> Axon.layer_norm(
      epsilon: config.layer_norm_eps,
      name: name <> ".LayerNorm",
      channel_index: 2
    )
    |> Axon.dropout(rate: config.hidden_dropout_prob, name: name <> ".dropout")
  end

  defp encoder(inputs, hidden_states, config, opts) do
    name = opts[:name]

    hidden_states =
      Axon.dense(hidden_states, config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "embedding_hidden_mapping_in")
      )

    albert_layer_groups(inputs, hidden_states, config, name: join(name, "albert_layer_groups"))
  end

  defp albert_layer_groups(inputs, hidden_states, config, opts) do
    name = opts[:name]

    last_hidden_state = hidden_states
    all_hidden_states = {last_hidden_state}
    all_attentions = {}

    initial_state = {last_hidden_state, all_hidden_states, all_attentions}

    for idx <- 0..(config.num_hidden_layers - 1), reduce: initial_state do
      {last, states, attentions} ->
        group_idx = div(idx, div(config.num_hidden_layers, config.num_hidden_groups))

        albert_layers(inputs, last, states, attentions, config,
          name: name |> join(group_idx) |> join("albert_layers")
        )
    end
  end

  defp albert_layers(inputs, hidden_states, all_hidden_states, all_attentions, config, opts) do
    name = opts[:name]

    initial_state = {hidden_states, all_hidden_states, all_attentions}

    for idx <- 0..(config.inner_group_num - 1), reduce: initial_state do
      {last, states, attentions} ->
        {next_state, next_attention} = albert_layer(inputs, last, config, name: join(name, idx))
        {next_state, Tuple.append(states, next_state), Tuple.append(attentions, next_attention)}
    end
  end

  defp albert_layer(inputs, hidden_states, config, opts) do
    name = opts[:name]

    {attention_output, attention_weights} =
      self_attention(hidden_states, inputs["attention_mask"], config,
        name: join(name, "attention")
      )

    hidden_states =
      attention_output
      |> Axon.dense(config.intermediate_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "ffn")
      )
      |> Layers.activation_layer(config.hidden_act, name: join(name, "ffn.activation"))
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "ffn_output")
      )
      |> Axon.dropout(rate: config.hidden_dropout_prob, name: join(name, "ffn_output.dropout"))
      |> Axon.add(attention_output, name: join(name, "ffn.residual"))
      |> Axon.layer_norm(
        epsilon: config.layer_norm_eps,
        name: join(name, "full_layer_layer_norm"),
        channel_index: 2
      )

    {hidden_states, attention_weights}
  end

  defp self_attention(hidden_states, attention_mask, config, opts) do
    name = opts[:name]

    head_dim = div(config.hidden_size, config.num_attention_heads)

    query_states =
      hidden_states
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "query")
      )
      |> Axon.reshape({:auto, config.num_attention_heads, head_dim})

    value_states =
      hidden_states
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "value")
      )
      |> Axon.reshape({:auto, config.num_attention_heads, head_dim})

    key_states =
      hidden_states
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "key")
      )
      |> Axon.reshape({:auto, config.num_attention_heads, head_dim})

    attention_bias = Axon.layer(&Layers.attention_bias/2, [attention_mask])

    attention_weights =
      Axon.layer(&Layers.attention_weights/4, [query_states, key_states, attention_bias])

    attention_weights =
      Axon.dropout(attention_weights,
        rate: config.attention_probs_dropout_prob,
        name: join(name, "dropout")
      )

    attention_output = Axon.layer(&Layers.attention_output/3, [attention_weights, value_states])

    attention_output =
      Axon.reshape(attention_output, {:auto, config.num_attention_heads * head_dim})

    projected =
      attention_output
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        name: join(name, "dense")
      )
      |> Axon.dropout(rate: config.hidden_dropout_prob, name: join(name, "dense.dropout"))
      |> Axon.add(hidden_states)
      |> Axon.layer_norm(
        epsilon: config.layer_norm_eps,
        name: join(name, "LayerNorm"),
        channel_index: 2
      )

    {projected, attention_weights}
  end

  defp pooler(hidden_states, config, opts) do
    name = opts[:name]

    hidden_states
    |> Layers.take_token_layer(axis: 1)
    |> Axon.dense(config.hidden_size,
      kernel_initializer: kernel_initializer(config),
      name: name
    )
    |> Axon.tanh(name: join(name, "tanh"))
  end

  defp lm_prediction_head(hidden_state, config, opts) do
    name = opts[:name]

    # TODO: use a shared parameter with embeddings.word_embeddings.kernel
    # if config.tie_word_embeddings is true (relevant for training)

    hidden_state
    |> lm_prediction_head_transform(config, name: name)
    # We reuse the kernel of input embeddings and add bias for each token
    |> Layers.dense_transposed_layer(config.vocab_size,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "decoder")
    )
  end

  defp lm_prediction_head_transform(hidden_state, config, opts) do
    name = opts[:name]

    hidden_state
    |> Axon.dense(config.embedding_size,
      kernel_initializer: kernel_initializer(config),
      name: name <> ".dense"
    )
    |> Layers.activation_layer(config.hidden_act, name: name <> ".activation")
    |> Axon.layer_norm(
      epsilon: config.layer_norm_eps,
      name: name <> ".LayerNorm",
      channel_index: 2
    )
  end

  defp classifier_dropout_rate(config) do
    config.classifier_dropout_prob || config.hidden_dropout_prob
  end

  defp kernel_initializer(config) do
    Axon.Initializers.normal(scale: config.initializer_range)
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    def load(config, data) do
      data
      |> Shared.convert_to_atom(["position_embedding_type", "hidden_act"])
      |> Shared.convert_common()
      |> Shared.data_into_config(config, except: [:architecture])
    end
  end
end