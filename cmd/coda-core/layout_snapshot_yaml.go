package main

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

func generateLayoutYAML(snap *snapshot) ([]byte, error) {
	cfg := snapshotToConfig(snap)
	return yaml.Marshal(cfg)
}

func snapshotToConfig(snap *snapshot) *LayoutConfig {
	tree := parseLayoutTree(snap.LayoutStr)
	paneMap := make(map[string]paneInfo)
	for _, p := range snap.Panes {
		paneMap[p.ID] = p
	}

	hasTitles := false
	for _, p := range snap.Panes {
		if resolveTitle(p.Title) != "" {
			hasTitles = true
			break
		}
	}

	cfg := &LayoutConfig{
		Direction: tree.direction,
		Panes:     treeNodeToConfig(tree, paneMap),
	}

	if hasTitles {
		cfg.Border = &BorderConfig{
			Status: "top",
			Lines:  "heavy",
		}
	}

	return cfg
}

type layoutNode struct {
	direction string
	children  []layoutChild
}

type layoutChild struct {
	width, height int
	paneID        string
	subNode       *layoutNode
}

func treeNodeToConfig(node *layoutNode, paneMap map[string]paneInfo) []PaneConfig {
	var panes []PaneConfig
	totalSize := 0
	for _, c := range node.children {
		if node.direction == "horizontal" {
			totalSize += c.width
		} else {
			totalSize += c.height
		}
	}

	for _, c := range node.children {
		var pct int
		if node.direction == "horizontal" && totalSize > 0 {
			pct = (c.width * 100) / totalSize
		} else if totalSize > 0 {
			pct = (c.height * 100) / totalSize
		}
		if pct < 1 && totalSize > 0 {
			pct = 1
		}
		size := fmt.Sprintf("%d%%", pct)

		if c.subNode != nil {
			subPanes := treeNodeToConfig(c.subNode, paneMap)
			panes = append(panes, PaneConfig{
				Direction: c.subNode.direction,
				Panes:     subPanes,
				Size:      size,
			})
		} else {
			pi := paneMap[c.paneID]
			cmd := resolveCmd(pi.Start, pi.Cmd)
			title := resolveTitle(pi.Title)
			pc := PaneConfig{Size: size}
			if cmd != "" {
				pc.Command = cmd
			}
			if title != "" {
				pc.Title = title
			}
			panes = append(panes, pc)
		}
	}

	return panes
}

// parseLayoutTree parses a tmux layout string into a tree structure.
// Layout strings look like: "checksum,WxH,X,Y{...}" or "checksum,WxH,X,Y[...]" or "checksum,WxH,X,Y,ID"
// { } = horizontal split, [ ] = vertical split
func parseLayoutTree(layout string) *layoutNode {
	idx := strings.Index(layout, ",")
	if idx < 0 {
		return &layoutNode{direction: "horizontal"}
	}
	body := layout[idx+1:]

	node, _ := parseLayoutBody(body, 0)
	if node == nil {
		return &layoutNode{direction: "horizontal"}
	}
	return node
}

func parseLayoutBody(s string, pos int) (*layoutNode, int) {
	w, h, newPos := parseDimensions(s, pos)
	if newPos < 0 {
		return nil, pos
	}
	pos = newPos

	if pos >= len(s) {
		return &layoutNode{
			direction: "horizontal",
			children:  []layoutChild{{width: w, height: h}},
		}, pos
	}

	switch s[pos] {
	case '{':
		children, end := parseChildren(s, pos+1, '}')
		return &layoutNode{direction: "horizontal", children: setDimensions(children, w, h)}, end
	case '[':
		children, end := parseChildren(s, pos+1, ']')
		return &layoutNode{direction: "vertical", children: setDimensions(children, w, h)}, end
	case ',':
		id, end := parseID(s, pos+1)
		return &layoutNode{
			direction: "horizontal",
			children:  []layoutChild{{width: w, height: h, paneID: id}},
		}, end
	default:
		return nil, pos
	}
}

func parseDimensions(s string, pos int) (w, h, newPos int) {
	var num int
	start := pos
	for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
		num = num*10 + int(s[pos]-'0')
		pos++
	}
	if pos == start || pos >= len(s) || s[pos] != 'x' {
		return 0, 0, -1
	}
	w = num
	pos++

	num = 0
	start = pos
	for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
		num = num*10 + int(s[pos]-'0')
		pos++
	}
	if pos == start {
		return 0, 0, -1
	}
	h = num

	if pos >= len(s) || s[pos] != ',' {
		return 0, 0, -1
	}
	pos++

	for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
		pos++
	}
	if pos >= len(s) || s[pos] != ',' {
		return 0, 0, -1
	}
	pos++

	for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
		pos++
	}

	return w, h, pos
}

func parseChildren(s string, pos int, closer byte) ([]layoutChild, int) {
	var children []layoutChild
	for pos < len(s) && s[pos] != closer {
		if s[pos] == ',' {
			pos++
			continue
		}
		node, end := parseLayoutBody(s, pos)
		if node == nil || end == pos {
			break
		}
		if len(node.children) == 1 && node.children[0].subNode == nil {
			c := node.children[0]
			children = append(children, layoutChild{
				width:  c.width,
				height: c.height,
				paneID: c.paneID,
			})
		} else {
			w, h := node.children[0].width, node.children[0].height
			for _, c := range node.children {
				if c.width > w {
					w = c.width
				}
				if c.height > h {
					h = c.height
				}
			}
			children = append(children, layoutChild{
				width:   w,
				height:  h,
				subNode: node,
			})
		}
		pos = end
	}
	if pos < len(s) && s[pos] == closer {
		pos++
	}
	return children, pos
}

func parseID(s string, pos int) (string, int) {
	start := pos
	for pos < len(s) && s[pos] >= '0' && s[pos] <= '9' {
		pos++
	}
	return s[start:pos], pos
}

func setDimensions(children []layoutChild, w, h int) []layoutChild {
	if len(children) == 0 {
		return children
	}
	for i := range children {
		if children[i].width == 0 {
			children[i].width = w
		}
		if children[i].height == 0 {
			children[i].height = h
		}
	}
	return children
}

func writeLayoutYAML(snap *snapshot, outputPath string) error {
	data, err := generateLayoutYAML(snap)
	if err != nil {
		return fmt.Errorf("generating YAML: %w", err)
	}
	if err := os.WriteFile(outputPath, data, 0644); err != nil {
		return fmt.Errorf("writing YAML file: %w", err)
	}
	return nil
}
