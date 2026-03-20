// Parse calligraphy DOT output into Cytoscape.js
// elements — flat nodes (no compound parents), colored
// by kind.
//
// Calligraphy shapes:
//   octagon  -> type (data/newtype/class)
//   box      -> constructor
//   ellipse  -> function/value
//   rounded  -> record field

export const parseDot = (dotString) => () => {
  var nodes = [];
  var edges = [];
  var currentModule = null;
  var nodeModules = {};

  var lines = dotString.split("\n");

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();

    // Module label
    var labelMatch = line.match(/^label="([^"]+)"/);
    if (labelMatch) {
      currentModule = labelMatch[1];
      continue;
    }

    // Node definition
    var nodeMatch = line.match(
      /node_(\d+)\s*\[label="([^"]+)"(?:,shape=(\w+))?/
    );
    if (nodeMatch) {
      var nodeId = "node_" + nodeMatch[1];
      var nodeLabel = nodeMatch[2];
      var shape = nodeMatch[3] || "ellipse";

      var kind;
      if (shape === "octagon") {
        kind = "type";
      } else if (shape === "box") {
        if (line.indexOf("rounded") !== -1) {
          kind = "field";
        } else {
          kind = "constructor";
        }
      } else {
        kind = "function";
      }

      var displayLabel = currentModule
        ? currentModule + "." + nodeLabel
        : nodeLabel;

      nodeModules[nodeId] = currentModule;

      nodes.push({
        group: "nodes",
        data: {
          id: nodeId,
          label: nodeLabel,
          fullLabel: displayLabel,
          kind: kind,
          module: currentModule || "",
        },
        classes: kind,
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
        line.indexOf("style=dashed") !== -1 &&
        line.indexOf("arrowhead=none") !== -1;
      var isDotted =
        line.indexOf("style=dotted") !== -1;
      var isBack = line.indexOf("dir=back") !== -1;

      // dashed+arrowhead=none = parent-child tree
      // (skip — we're flat)
      if (isDashed) continue;

      var source = isBack ? tgtId : srcId;
      var target = isBack ? srcId : tgtId;
      var cls = isDotted ? "type-edge" : "";

      edges.push({
        group: "edges",
        data: {
          id: "e_" + source + "_" + target,
          source: source,
          target: target,
        },
        classes: cls,
      });
    }
  }

  return nodes.concat(edges);
};
