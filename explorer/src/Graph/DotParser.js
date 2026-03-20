// Parse calligraphy DOT output into Cytoscape.js elements.
//
// Calligraphy produces DOT with:
//   - subgraph cluster_module_* for modules
//   - subgraph cluster_node_* for type/value trees
//   - node_N [label="name", shape=...] for nodes
//   - "node_N" -> "node_M" edges (with dir=back or
//     style=dashed for parent-child)
//
// We classify nodes by shape:
//   octagon  -> type (data/newtype/class)
//   box      -> constructor
//   ellipse  -> function/value
//   rounded  -> record field

export const parseDot = (dotString) => () => {
  var nodes = [];
  var edges = [];
  var parentStack = [];
  var moduleStack = [];
  var currentModule = null;
  var nodeParents = {};

  var lines = dotString.split("\n");

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();

    // Module cluster
    var moduleMatch = line.match(
      /subgraph\s+cluster_module_\w+\s*\{/
    );
    if (moduleMatch) {
      moduleStack.push(currentModule);
      continue;
    }

    // Label for module
    var labelMatch = line.match(/^label="([^"]+)"/);
    if (labelMatch && moduleStack.length > 0) {
      var moduleName = labelMatch[1];
      var moduleId = "module_" + moduleName;
      currentModule = moduleId;
      nodes.push({
        group: "nodes",
        data: {
          id: moduleId,
          label: moduleName,
          kind: "module",
        },
        classes: "module",
      });
      continue;
    }

    // Node cluster (type tree parent-child)
    var clusterMatch = line.match(
      /subgraph\s+cluster_node_(\d+)\s*\{/
    );
    if (clusterMatch) {
      parentStack.push(clusterMatch[1]);
      continue;
    }

    // Closing brace
    if (line === "}") {
      if (parentStack.length > 0) {
        parentStack.pop();
      } else if (moduleStack.length > 0) {
        currentModule = moduleStack.pop();
      }
      continue;
    }

    // Node definition
    var nodeMatch = line.match(
      /node_(\d+)\s*\[label="([^"]+)"(?:,shape=(\w+))?/
    );
    if (nodeMatch) {
      var nodeNum = nodeMatch[1];
      var nodeLabel = nodeMatch[2];
      var shape = nodeMatch[3] || "ellipse";
      var nodeId = "node_" + nodeNum;

      var kind;
      var cls;
      if (shape === "octagon") {
        kind = "type";
        cls = "type";
      } else if (shape === "box") {
        kind = "constructor";
        cls = "constructor";
      } else if (
        shape === "ellipse" ||
        line.indexOf("rounded") !== -1
      ) {
        kind = "function";
        cls = "function";
      } else {
        kind = "function";
        cls = "function";
      }

      // Determine parent: innermost cluster or module
      var parentId = null;
      if (parentStack.length > 0) {
        parentId = "node_" + parentStack[parentStack.length - 1];
      } else if (currentModule) {
        parentId = currentModule;
      }

      nodeParents[nodeId] = parentId;

      var nodeData = {
        id: nodeId,
        label: nodeLabel,
        kind: kind,
      };
      if (parentId) {
        nodeData.parent = parentId;
      }

      nodes.push({
        group: "nodes",
        data: nodeData,
        classes: cls,
      });
      continue;
    }

    // Edge definition
    var edgeMatch = line.match(
      /"node_(\d+)"\s*->\s*"node_(\d+)"/
    );
    if (edgeMatch) {
      var srcId = "node_" + edgeMatch[1];
      var tgtId = "node_" + edgeMatch[2];
      var isDashed =
        line.indexOf("style=dashed") !== -1;
      var isBack = line.indexOf("dir=back") !== -1;

      // Dashed + arrowhead=none = parent-child
      // (already captured by cluster nesting)
      if (isDashed) continue;

      // dir=back means the visual direction is
      // reversed
      var source = isBack ? tgtId : srcId;
      var target = isBack ? srcId : tgtId;
      var cls2 =
        line.indexOf("follow-type") !== -1
          ? "type-edge"
          : "";

      edges.push({
        group: "edges",
        data: {
          id: "e_" + source + "_" + target,
          source: source,
          target: target,
        },
        classes: cls2,
      });
    }
  }

  return nodes.concat(edges);
};
